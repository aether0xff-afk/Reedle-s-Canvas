import asyncio
from collections.abc import AsyncIterator, Callable, Coroutine
from contextlib import asynccontextmanager
import json
from secrets import compare_digest
from typing import Any

from anyio import CancelScope
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
import httpx
from starlette.concurrency import run_in_threadpool
from starlette.requests import ClientDisconnect
from starlette.types import Receive, Scope, Send

from .contract import ImageTooLarge, MAX_BODY_BYTES, ObserveRequest, bind_reply, parse_json, verified_png
from .provider import BazeTutor
from .resilience import AttemptBudget, GatewayProblem, ReplyCache
from .settings import Settings


class _PeerClosed(Response):
    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        # The ASGI receive channel has confirmed the transport is closed.
        return


class _ObservationStream(StreamingResponse):
    def __init__(self, request: Request, payload: ObserveRequest):
        self.events = _observe_events(request, payload)
        super().__init__(self.events, media_type="text/event-stream",
                         headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no", "Vary": "Accept"})

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        try:
            await super().__call__(scope, receive, send)
        except ClientDisconnect:
            pass
        finally:
            await self.events.aclose()


async def _connected_reply(request: Request, operation: Coroutine[Any, Any, dict[str, Any]]) -> dict[str, Any]:
    async def wait_for_disconnect() -> None:
        while (await request.receive())["type"] != "http.disconnect":
            pass

    disconnected = asyncio.create_task(wait_for_disconnect())
    reply = asyncio.create_task(operation)
    try:
        done, _ = await asyncio.wait((disconnected, reply), return_when=asyncio.FIRST_COMPLETED)
        if disconnected in done:
            await disconnected
            raise ClientDisconnect
        return await reply
    finally:
        for task in (disconnected, reply):
            if not task.done():
                task.cancel()
        await asyncio.gather(disconnected, reply, return_exceptions=True)


def create_app(*, provider_transport: httpx.AsyncBaseTransport | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        settings = Settings.from_env()
        budget = AttemptBudget(settings.budget_db, settings.daily_attempt_limit)
        replies: ReplyCache[dict[str, Any]] = ReplyCache(ttl=settings.reply_cache_seconds)
        async with httpx.AsyncClient(
            transport=provider_transport,
            headers={"Authorization": f"Bearer {settings.provider_key}", "Accept-Encoding": "identity"},
            timeout=settings.attempt_timeout,
            limits=httpx.Limits(max_connections=16, max_keepalive_connections=8),
            follow_redirects=False,
            trust_env=False,
        ) as client:
            app.state.settings = settings
            app.state.tutor = BazeTutor(settings, client, budget)
            app.state.replies = replies
            try:
                yield
            finally:
                await replies.close()

    app = FastAPI(title="Reedle Tutor Gateway", lifespan=lifespan)

    @app.exception_handler(GatewayProblem)
    async def problem_response(_: Request, problem: GatewayProblem) -> JSONResponse:
        headers = {"Cache-Control": "no-store"}
        if problem.status == 401:
            headers["WWW-Authenticate"] = "Bearer"
        if problem.retry_after is not None:
            headers["Retry-After"] = str(problem.retry_after)
        return JSONResponse({"detail": problem.code}, status_code=problem.status, headers=headers)

    @app.post("/v1/tutor/observe")
    async def observe(request: Request) -> Response:
        settings: Settings = request.app.state.settings
        _authenticate(request, settings.client_token)
        try:
            payload = await _read_request(request)
            if request.headers.get("accept", "").strip().lower() == "text/event-stream":
                return _ObservationStream(request, payload)
            reply = await _connected_reply(request, _observe(request, payload))
        except ClientDisconnect:
            return _PeerClosed()
        return JSONResponse(reply, headers={"Cache-Control": "no-store", "Vary": "Accept"})

    return app


def _event(name: str, data: dict[str, Any]) -> bytes:
    return f"event: {name}\ndata: {json.dumps(data, ensure_ascii=False, separators=(',', ':'))}\n\n".encode()


async def _observe_events(request: Request, payload: ObserveRequest) -> AsyncIterator[bytes]:
    first_delta = asyncio.Event()
    draft = asyncio.create_task(first_delta.wait())
    reply = asyncio.create_task(_observe(request, payload, first_delta.set))
    announced_draft = False
    try:
        yield _event("progress", {"phase": "reading"})
        while True:
            watched = (reply,) if announced_draft else (reply, draft)
            done, _ = await asyncio.wait(watched, timeout=0.75, return_when=asyncio.FIRST_COMPLETED)
            if not announced_draft and first_delta.is_set():
                announced_draft = True
                yield _event("progress", {"phase": "drafting"})
            if reply in done:
                break
            if not done:
                # Flush idle connections so disconnected peers are detected on ASGI 2.4+.
                yield b": keep-alive\n\n"
        yield _event("result", reply.result())
    except GatewayProblem as problem:
        yield _event("error", {"status": problem.status, "retryAfter": problem.retry_after})
    finally:
        for task in (draft, reply):
            if not task.done():
                task.cancel()
        with CancelScope(shield=True):
            await asyncio.gather(draft, reply, return_exceptions=True)


async def _observe(request: Request, payload: ObserveRequest,
                   on_delta: Callable[[], None] | None = None) -> dict[str, Any]:
    try:
        png = await run_in_threadpool(verified_png, payload.image)
    except ImageTooLarge:
        raise GatewayProblem(413, "image_too_large") from None
    except ValueError:
        raise GatewayProblem(422, "invalid_png") from None

    settings: Settings = request.app.state.settings
    tutor: BazeTutor = request.app.state.tutor
    replies: ReplyCache[dict[str, Any]] = request.app.state.replies

    async def generate() -> dict[str, Any]:
        draft = await tutor.generate(payload, png, on_delta)
        return bind_reply(payload, settings.provider_model, draft)

    return await replies.resolve(payload.observation.request_id, payload.fingerprint(png), generate)


def _authenticate(request: Request, expected: str) -> None:
    headers = request.headers.getlist("authorization")
    if len(headers) == 1:
        scheme, _, token = headers[0].partition(" ")
        if scheme.lower() == "bearer" and compare_digest(token.encode("utf-8"), expected.encode("ascii")):
            return
    raise GatewayProblem(401, "unauthorized")


async def _read_request(request: Request) -> ObserveRequest:
    media_type = request.headers.get("content-type", "").partition(";")[0].strip().lower()
    if media_type != "application/json":
        raise GatewayProblem(415, "expected_json")

    length = request.headers.get("content-length")
    if length is not None:
        if not length.isascii() or not length.isdecimal():
            raise GatewayProblem(400, "invalid_content_length")
        if len(length) > 6 or int(length) > MAX_BODY_BYTES:
            raise GatewayProblem(413, "request_too_large")

    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_BODY_BYTES:
            raise GatewayProblem(413, "request_too_large")
        body.extend(chunk)
    try:
        return ObserveRequest.model_validate(parse_json(body))
    except (ValueError, RecursionError):
        raise GatewayProblem(422, "invalid_observation") from None


app = create_app()
