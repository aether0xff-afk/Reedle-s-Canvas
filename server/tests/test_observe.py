import asyncio
import base64
from contextlib import asynccontextmanager
from io import BytesIO
import json
from pathlib import Path
from uuid import UUID, uuid4

import httpx
from jsonschema import Draft202012Validator, FormatChecker
from PIL import Image, ImageDraw
import pytest

from reedle_server.app import create_app
from reedle_server.resilience import ReplyCache


PATH = "/v1/tutor/observe"
AUTH = {"Authorization": "Bearer test-client-token"}
ENTITY = "0ca30907-01e3-4ea1-9731-370bf0294e26"
OTHER_ENTITY = "bf69584e-2a88-4326-85c8-1a9a9eb098cc"
PROVIDER_MARKER = "upstream-private-marker"
CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"
pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture(autouse=True)
def configure_gateway(monkeypatch, tmp_path):
    monkeypatch.setenv("REEDLE_CLIENT_TOKEN", "test-client-token")
    monkeypatch.setenv("BAZE_API_KEY", "test-provider-key")
    monkeypatch.setenv("BAZE_MODEL", "mock-vision-model")
    monkeypatch.setenv("BAZE_BASE_URL", "https://mock.baze.test/v1/gateway")
    monkeypatch.setenv("REEDLE_BUDGET_DB", str(tmp_path / "budget.sqlite3"))
    monkeypatch.setenv("REEDLE_DAILY_ATTEMPT_LIMIT", "100")
    monkeypatch.setenv("REEDLE_PROVIDER_TIMEOUT_SECONDS", "7")
    monkeypatch.setenv("REEDLE_PROVIDER_MAX_ATTEMPTS", "2")
    monkeypatch.setenv("REEDLE_REPLY_CACHE_SECONDS", "300")


@asynccontextmanager
async def client(handler):
    app = create_app(provider_transport=httpx.MockTransport(handler))
    transport = httpx.ASGITransport(app=app)
    async with app.router.lifespan_context(app), httpx.AsyncClient(
        base_url="http://gateway.test", transport=transport,
    ) as gateway:
        yield gateway


def png(width=12, height=8, *, ink=None):
    with BytesIO() as stream:
        image = Image.new("RGB", (width, height), "white")
        if ink is not None:
            ImageDraw.Draw(image).text((12, 12), ink, fill="black", font_size=32)
        image.save(stream, "PNG")
        return stream.getvalue()


def observation(*, revision=3, note_id=None, ink=None):
    return {
        "observation": {
            "schemaVersion": 1,
            "requestId": str(uuid4()),
            "noteId": note_id or str(uuid4()),
            "canvasRevision": revision,
            "focusBounds": {"x": -300, "y": 40, "width": 240, "height": 180},
            "entityIds": [ENTITY],
        },
        "image": base64.b64encode(png(240, 120, ink=ink) if ink is not None else png()).decode("ascii"),
        "entities": [{"id": ENTITY, "x": 0.1, "y": 0.2, "width": 0.6, "height": 0.5}],
    }


def draft():
    return {
        "reason": "덧셈을 다시 확인할 수 있도록 질문합니다.",
        "recognition": {
            "kind": "math",
            "transcript": "2+2=5",
            "confidence": 0.96,
            "targetEntityIds": [ENTITY],
        },
        "decision": "act",
        "actions": [
            {
                "type": "ask_question",
                "placementIntent": "below",
                "targetEntityId": ENTITY,
                "content": "두 개에 두 개를 더하면 모두 몇 개일까요?",
            }
        ],
    }


def completion(value, *, finish_reason="stop", usage=None, billing=None):
    content = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return httpx.Response(
        200,
        json={
            "choices": [
                {"finish_reason": finish_reason, "message": {"role": "assistant", "content": content}}
            ],
            "model": PROVIDER_MARKER,
            "usage": usage or {"prompt_tokens": 300, "completion_tokens": 85, "total_tokens": 385},
            "billing": billing,
        },
    )


def assert_contract(response, sent):
    schema = json.loads((CONTRACTS / "tutor-response-v1.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(response)
    assert response["requestId"] == sent["observation"]["requestId"]
    assert response["noteId"] == sent["observation"]["noteId"]
    assert response["observedRevision"] == sent["observation"]["canvasRevision"]


@pytest.mark.parametrize("ending", ["complete", "null_role", "truncated", "length", "tool_call", "invalid_anchor"])
async def test_stream_provides_phases_and_only_binds_a_complete_valid_draft(ending, caplog):
    payload = observation(ink="2+2=5")
    value = draft()
    if ending == "invalid_anchor":
        value["actions"][0]["targetEntityId"] = OTHER_ENTITY
    content = json.dumps(value, ensure_ascii=False)

    def chunk(delta, finish=None):
        return {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

    async def provider(request):
        sent = json.loads(request.content)
        assert sent["stream"] is True
        assert sent["stream_options"] == {"include_usage": True}
        frames = [chunk({"role": "assistant"}), chunk({"content": content[:97]}), chunk({"content": content[97:]})]
        if ending == "tool_call":
            frames.append(chunk({"tool_calls": [{"id": PROVIDER_MARKER}]}))
        frames.append(chunk({}, "length" if ending == "length" else "stop"))
        if ending == "null_role":
            # BAZE includes role:null on continuation and terminal deltas.
            for frame in frames[1:]:
                frame["choices"][0]["delta"]["role"] = None
        frames.append({"choices": [], "usage": {"prompt_tokens": 300, "completion_tokens": 85, "total_tokens": 385},
                       "billing": {"cost_usd": 0.00053, "deducted_credit": 0.7211, "extra": PROVIDER_MARKER}})
        wire = "".join(f"data: {json.dumps(frame, ensure_ascii=False)}\r\n\r\n" for frame in frames)
        if ending != "truncated":
            wire += "data: [DONE]\r\n\r\n"
        return httpx.Response(200, content=wire.encode(), headers={"Content-Type": "text/event-stream"})

    caplog.set_level("INFO", logger="uvicorn.error.reedle")
    async with client(provider) as gateway:
        response = await gateway.post(PATH, json=payload, headers={**AUTH, "Accept": "text/event-stream"})
        replay = await gateway.post(PATH, json=payload, headers=AUTH)
    assert response.status_code == 200
    assert response.headers["content-type"].split(";")[0] == "text/event-stream"
    reading, drafting, result = response.text.strip().split("\n\n")
    assert reading == 'event: progress\ndata: {"phase":"reading"}'
    assert drafting == 'event: progress\ndata: {"phase":"drafting"}'
    name, data = result.split("\n", 1)
    assert name == "event: result"
    reply = json.loads(data.removeprefix("data: "))
    assert reply == replay.json()
    assert_contract(reply["response"], payload)
    assert PROVIDER_MARKER not in response.text
    assert "billing" not in reply and PROVIDER_MARKER not in caplog.text
    if ending in ("complete", "null_role"):
        assert reply["response"]["actions"][0]["content"] == value["actions"][0]["content"]
        assert "prompt_tokens=300 completion_tokens=85 total_tokens=385" in caplog.text
        assert "cost_usd=0.00053 deducted_credit=0.7211" in caplog.text
    else:
        assert reply["response"]["actions"] == []
        assert reply["response"]["decision"] == "observe_only"


async def test_vision_gateway_gives_a_hint_then_acknowledges_the_correction(caplog):
    first = observation(ink="2+2=5")
    second = observation(revision=4, note_id=first["observation"]["noteId"], ink="4")
    second["recent"] = [
        {
            "revision": 3,
            "kind": "math",
            "transcript": "2+2=5",
            "feedback": draft()["actions"][0]["content"],
        }
    ]
    calls = []

    def provider(request):
        assert request.method == "POST"
        assert request.url == "https://mock.baze.test/v1/gateway/chat/completions/"
        assert request.headers["authorization"] == "Bearer test-provider-key"
        payload = json.loads(request.content)
        assert payload["model"] == "mock-vision-model"
        assert payload["stream"] is False
        assert payload["response_format"]["type"] == "json_schema"
        assert payload["response_format"]["json_schema"]["strict"] is True
        assert payload["response_format"]["json_schema"]["schema"]["additionalProperties"] is False
        pending = first if not calls else second
        user = payload["messages"][-1]["content"]
        assert user[1] == {"type": "image_url", "image_url": {"url": "data:image/png;base64," + pending["image"]}}
        context = json.loads(user[0]["text"])
        assert context["entities"] == pending["entities"]
        assert "-300" not in user[0]["text"]
        assert pending["observation"]["noteId"] not in user[0]["text"]
        assert pending["observation"]["requestId"] not in user[0]["text"]
        calls.append(context)
        if len(calls) == 1:
            return completion(draft(), billing={"cost_usd": 0.00053, "deducted_credit": PROVIDER_MARKER})
        acknowledged = draft()
        acknowledged["recognition"]["transcript"] = "4"
        acknowledged.update(reason="4가 맞아요.", decision="observe_only", actions=[])
        return completion(acknowledged)

    caplog.set_level("INFO", logger="uvicorn.error.reedle")
    async with client(provider) as gateway:
        hinted = await gateway.post(PATH, headers=AUTH, json=first)
        acknowledged = await gateway.post(PATH, headers=AUTH, json=second)
    assert hinted.status_code == acknowledged.status_code == 200
    assert calls[0]["recent"] == [] and calls[1]["recent"] == second["recent"]
    hint = hinted.json()
    assert hint["model"] == "mock-vision-model"
    assert hint["recognition"] == draft()["recognition"]
    assert hint["response"]["decision"] == "act"
    assert hint["response"]["actions"][0]["targetEntityId"] == ENTITY
    assert UUID(hint["response"]["actions"][0]["actionId"]).version == 5
    assert_contract(hint["response"], first)
    assert acknowledged.json()["reason"] == "4가 맞아요."
    assert acknowledged.json()["recognition"]["transcript"] == "4"
    assert acknowledged.json()["response"]["actions"] == []
    assert_contract(acknowledged.json()["response"], second)
    assert "prompt_tokens=300" in caplog.text and "latency_ms=" in caplog.text
    assert "cost_usd=0.00053 deducted_credit=None" in caplog.text
    assert "billing" not in hint
    assert "2+2=5" not in caplog.text and PROVIDER_MARKER not in caplog.text


async def test_unchanged_work_with_an_existing_hint_does_not_get_flagged_again():
    payload = observation(revision=4, ink="2+2=5")
    payload["recent"] = [{
        "revision": 3, "kind": "math", "transcript": "２ + ２ = ５",
        "feedback": "덧셈을 다시 확인해 보세요.", "offeredHint": True,
    }]
    async with client(lambda _: completion(draft())) as gateway:
        reply = await gateway.post(PATH, headers=AUTH, json=payload)
        assert reply.status_code == 200
        assert reply.json()["recognition"]["transcript"] == "2+2=5"
        assert reply.json()["response"]["decision"] == "observe_only"
        assert reply.json()["response"]["actions"] == []
        assert_contract(reply.json()["response"], payload)


@pytest.mark.parametrize(
    "alter",
    [
        lambda reply: reply["actions"][0].update(targetEntityId=OTHER_ENTITY),
        lambda reply: reply["recognition"].update(targetEntityIds=[OTHER_ENTITY]),
        lambda reply: reply["recognition"].update(targetEntityIds=[ENTITY, ENTITY.upper()]),
        lambda reply: reply["actions"][0].update(x=0.5, y=0.5),
        lambda reply: reply["actions"][0].update(type="erase"),
        lambda reply: reply["actions"][0].update(type="draw", content="hexagon"),
        lambda reply: reply["actions"][0].update(type="write", content="```python\nprint(4)\n```"),
        lambda reply: reply["actions"][0].update(type="write", content="print(4)"),
        lambda reply: reply["recognition"].update(confidence="0.98"),
        lambda reply: reply["recognition"].update(confidence=float("inf")),
        lambda reply: reply["recognition"].update(transcript="글" * 342),
        lambda reply: reply.update(reason="안" * 171),
        lambda reply: reply.update(decision="observe_only"),
        lambda reply: reply.update(actions=reply["actions"] * 5),
        lambda reply: reply.update(noteId=str(uuid4())),
    ],
)
async def test_invalid_provider_draft_cannot_mutate_canvas(alter):
    payload = observation()
    reply = draft()
    reply["reason"] = PROVIDER_MARKER
    alter(reply)
    async with client(lambda _: completion(reply)) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=payload)
    assert response.status_code == 200
    assert PROVIDER_MARKER not in response.text
    assert response.json()["recognition"] == {
        "kind": "unknown", "transcript": "", "confidence": 0.0, "targetEntityIds": []
    }
    canonical = response.json()["response"]
    assert canonical["decision"] == "observe_only" and canonical["actions"] == []
    assert_contract(canonical, payload)


@pytest.mark.parametrize("content, finish_reason", [(PROVIDER_MARKER, "stop"), (draft(), "length")])
async def test_missing_or_incomplete_structured_output_is_observe_only(content, finish_reason):
    async with client(lambda _: completion(content, finish_reason=finish_reason)) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=observation())
    assert response.status_code == 200
    assert response.json()["response"]["decision"] == "observe_only"
    assert PROVIDER_MARKER not in response.text


@pytest.mark.parametrize("confidence, decision", [(0.81999, "observe_only"), (0.82, "act")])
async def test_action_requires_confidence_of_at_least_point_eight_two(confidence, decision):
    reply = draft()
    reply["recognition"]["confidence"] = confidence
    async with client(lambda _: completion(reply)) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=observation())
    assert response.status_code == 200
    assert response.json()["recognition"]["confidence"] == confidence
    assert response.json()["response"]["decision"] == decision
    if decision == "observe_only":
        assert response.json()["reason"] != reply["reason"]
        assert response.json()["response"]["actions"] == []


@pytest.mark.parametrize("kind, action_target, confidence", [("math", OTHER_ENTITY, 0), ("unknown", ENTITY, 0.96)])
async def test_tutor_actions_require_a_known_subject_and_recognized_target(kind, action_target, confidence):
    payload = observation()
    payload["observation"]["entityIds"].append(OTHER_ENTITY)
    payload["entities"].append({**payload["entities"][0], "id": OTHER_ENTITY})
    reply = draft()
    reply["recognition"]["kind"] = kind
    reply["actions"][0]["targetEntityId"] = action_target
    async with client(lambda _: completion(reply)) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=payload)
    assert response.status_code == 200
    assert response.json()["recognition"]["kind"] == "unknown"
    assert response.json()["recognition"]["confidence"] == confidence
    assert response.json()["reason"] != reply["reason"]
    assert response.json()["response"]["decision"] == "observe_only"
    assert response.json()["response"]["actions"] == []


def unreachable(_):
    pytest.fail("invalid input must not reach BAZE")


@pytest.mark.parametrize("authorization", [None, "Bearer test-provider-key", "Basic test-client-token"])
async def test_authentication_precedes_reading_a_body(authorization):
    headers = {"Authorization": authorization} if authorization else {}
    async with client(unreachable) as gateway:
        response = await gateway.post(PATH, headers=headers, content=b"x" * 750_001)
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


@pytest.mark.parametrize(
    "content, expected",
    [(b"{", 422), (b'{"image":"x","image":"y"}', 422), (b"\xff", 422), (b"x" * 750_001, 413)],
)
async def test_rejects_malformed_or_oversize_body(content, expected):
    async with client(unreachable) as gateway:
        response = await gateway.post(PATH, headers={**AUTH, "Content-Type": "application/json"}, content=content)
    assert response.status_code == expected
    assert "input" not in response.json()


async def test_rejects_oversize_chunked_body():
    async def chunks():
        yield b"x" * 500_000
        yield b"x" * 250_001

    async with client(unreachable) as gateway:
        response = await gateway.post(PATH, headers={**AUTH, "Content-Type": "application/json"}, content=chunks())
    assert response.status_code == 413


@pytest.mark.parametrize(
    "alter, expected",
    [
        (lambda payload: payload.update(image="not*base64"), 422),
        (lambda payload: payload.update(image=base64.b64encode(b"not PNG").decode("ascii")), 422),
        (lambda payload: payload.update(image=base64.b64encode(png()[:-2]).decode("ascii")), 422),
        (lambda payload: payload.update(image=base64.b64encode(png() + b"hidden data").decode("ascii")), 422),
        (lambda payload: payload.update(image=base64.b64encode(png(1281, 1)).decode("ascii")), 413),
        (lambda payload: payload.update(image=base64.b64encode(b"x" * (512 * 1024 + 1)).decode("ascii")), 413),
        (lambda payload: payload["observation"].update(schemaVersion=True), 422),
        (lambda payload: payload["observation"].update(canvasRevision=2**63), 422),
        (lambda payload: payload["observation"].update(entityIds=[ENTITY, ENTITY.upper()]), 422),
        (lambda payload: payload["entities"][0].update(id=OTHER_ENTITY), 422),
        (lambda payload: payload["entities"][0].update(x="0.1"), 422),
        (lambda payload: payload["entities"][0].update(x=0.5, width=0.6), 422),
        (lambda payload: payload.update(recent=[{"revision": 3, "kind": "math", "transcript": "4", "feedback": ""}]), 422),
    ],
)
async def test_rejects_invalid_observation_metadata_or_image(alter, expected):
    payload = observation()
    alter(payload)
    async with client(unreachable) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=payload)
    assert response.status_code == expected


async def test_same_input_reuses_result_and_changed_input_conflicts():
    calls = []

    def provider(request):
        calls.append(request)
        return completion(draft())

    payload = observation()
    async with client(provider) as gateway:
        first = await gateway.post(PATH, headers=AUTH, json=payload)
        payload["observation"]["requestId"] = payload["observation"]["requestId"].upper()
        duplicate = await gateway.post(PATH, headers=AUTH, json=payload)
        payload["observation"]["canvasRevision"] += 1
        changed = await gateway.post(PATH, headers=AUTH, json=payload)
    assert first.status_code == duplicate.status_code == 200
    assert first.json() == duplicate.json()
    assert changed.status_code == 409
    assert len(calls) == 1


async def test_same_pending_request_coalesces_concurrent_calls():
    entered = asyncio.Event()
    release = asyncio.Event()
    calls = []

    async def provider(request):
        calls.append(request)
        entered.set()
        await asyncio.wait_for(release.wait(), 5)
        return completion(draft())

    payload = observation()
    async with client(provider) as gateway:
        first = asyncio.create_task(gateway.post(PATH, headers=AUTH, json=payload))
        await asyncio.wait_for(entered.wait(), 5)
        try:
            duplicate = asyncio.create_task(gateway.post(PATH, headers=AUTH, json=payload))
            changed = observation()
            changed["observation"]["requestId"] = payload["observation"]["requestId"]
            conflict = await gateway.post(PATH, headers=AUTH, json=changed)
        finally:
            release.set()
        original, repeated = await asyncio.gather(first, duplicate)
    assert conflict.status_code == 409
    assert original.json() == repeated.json()
    assert len(calls) == 1


async def test_action_ids_remain_stable_after_gateway_restart():
    payload = observation()
    reply = draft()
    reply["actions"].append({**reply["actions"][0], "type": "draw", "content": "underline"})
    async with client(lambda _: completion(reply)) as original:
        initial = await original.post(PATH, headers=AUTH, json=payload)
    async with client(lambda _: completion(reply)) as restarted:
        repeated = await restarted.post(PATH, headers=AUTH, json=payload)
    assert initial.status_code == repeated.status_code == 200
    assert initial.json() == repeated.json()
    actions = initial.json()["response"]["actions"]
    assert len(actions) == 2 and actions[0]["actionId"] != actions[1]["actionId"]


def disconnected_request(app, payload, *, partial=False):
    incoming = asyncio.Queue()
    incoming.put_nowait({"type": "http.request", "body": json.dumps(payload).encode(), "more_body": partial})
    outgoing = []

    async def send(event):
        outgoing.append(event)

    scope = {
        "type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"},
        "method": "POST", "scheme": "http", "http_version": "1.1", "path": PATH,
        "query_string": b"", "headers": [
            (b"content-type", b"application/json"),
            (b"authorization", AUTH["Authorization"].encode("ascii")),
        ],
    }
    task = asyncio.create_task(app(scope, incoming.get, send))
    return task, incoming, outgoing


async def test_disconnect_cancels_provider_work_and_allows_a_fresh_retry():
    started = asyncio.Event()
    cancelled = asyncio.Event()
    calls = 0

    async def provider(_):
        nonlocal calls
        calls += 1
        if calls == 1:
            started.set()
            try:
                await asyncio.Future()
            finally:
                cancelled.set()
        return completion(draft())

    app = create_app(provider_transport=httpx.MockTransport(provider))
    payload = observation(ink="2+2=5")
    async with app.router.lifespan_context(app):
        task, incoming, outgoing = disconnected_request(app, payload)
        await asyncio.wait_for(started.wait(), 3)
        incoming.put_nowait({"type": "http.disconnect"})
        await asyncio.wait_for(task, 3)
        await asyncio.wait_for(cancelled.wait(), 3)
        assert calls == 1
        assert outgoing == []
        async with httpx.AsyncClient(base_url="http://gateway.test", transport=httpx.ASGITransport(app=app)) as gateway:
            retry = await gateway.post(PATH, headers=AUTH, json=payload)
        assert retry.status_code == 200
        assert calls == 2


async def test_disconnect_during_request_upload_does_not_call_provider():
    app = create_app(provider_transport=httpx.MockTransport(unreachable))
    async with app.router.lifespan_context(app):
        task, incoming, outgoing = disconnected_request(app, observation(), partial=True)
        incoming.put_nowait({"type": "http.disconnect"})
        await asyncio.wait_for(task, 3)
    assert outgoing == []


async def test_cancelled_duplicate_does_not_abort_the_remaining_waiter():
    started = asyncio.Event()
    release = asyncio.Event()
    cancelled = asyncio.Event()
    cache = ReplyCache()
    calls = 0

    async def operation():
        nonlocal calls
        calls += 1
        started.set()
        try:
            await release.wait()
        except asyncio.CancelledError:
            cancelled.set()
            raise
        return "verified reply"

    first = asyncio.create_task(cache.resolve("id", b"body", operation))
    await asyncio.wait_for(started.wait(), 3)
    duplicate = asyncio.create_task(cache.resolve("id", b"body", operation))
    await asyncio.sleep(0)
    try:
        first.cancel()
        with pytest.raises(asyncio.CancelledError):
            await first
        assert not cancelled.is_set()
        release.set()
        assert await asyncio.wait_for(duplicate, 3) == "verified reply"
        assert await cache.resolve("id", b"body", operation) == "verified reply"
    finally:
        await cache.close()
    assert calls == 1


async def test_cached_response_expires_without_new_traffic():
    cache = ReplyCache(ttl=0.01)

    async def operation():
        return "small response"

    try:
        assert await cache.resolve("id", b"body", operation) == "small response"
        assert "id" in cache.cached
        async with asyncio.timeout(1):
            while cache.cached:
                await asyncio.sleep(0.01)
    finally:
        await cache.close()


async def test_retention_can_disable_completed_reply_caching(monkeypatch):
    monkeypatch.setenv("REEDLE_REPLY_CACHE_SECONDS", "0")
    calls = 0

    def provider(_):
        nonlocal calls
        calls += 1
        return completion(draft())

    payload = observation()
    async with client(provider) as gateway:
        first = await gateway.post(PATH, headers=AUTH, json=payload)
        replayed = await gateway.post(PATH, headers=AUTH, json=payload)
    assert first.status_code == replayed.status_code == 200
    assert first.json() == replayed.json()
    assert calls == 2


@pytest.mark.parametrize("status", [429, 502])
async def test_retries_transient_status_within_a_bounded_attempt_count(status):
    outcomes = iter([httpx.Response(status, headers={"Retry-After": "0"}), completion(draft())])
    async with client(lambda _: next(outcomes)) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=observation())
    assert response.status_code == 200


async def test_retries_after_a_provider_timeout(monkeypatch):
    monkeypatch.setenv("REEDLE_PROVIDER_TIMEOUT_SECONDS", "0.1")
    attempts = []

    async def provider(request):
        attempts.append(request)
        if len(attempts) == 1:
            await asyncio.sleep(1)
        return completion(draft())

    async with client(provider) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=observation())
    assert response.status_code == 200
    assert len(attempts) == 2


async def test_honors_a_rate_limit_retry_after_longer_than_its_retry_window():
    responses = iter([httpx.Response(429, headers={"Retry-After": "75"}, text=PROVIDER_MARKER)])
    async with client(lambda _: next(responses)) as gateway:
        first = await gateway.post(PATH, headers=AUTH, json=observation())
        next_request = await gateway.post(PATH, headers=AUTH, json=observation())
    assert first.status_code == next_request.status_code == 503
    assert int(first.headers["retry-after"]) >= 74
    assert PROVIDER_MARKER not in first.text


async def test_circuit_opens_after_three_failed_calls(monkeypatch):
    monkeypatch.setenv("REEDLE_PROVIDER_MAX_ATTEMPTS", "1")
    responses = iter([httpx.Response(503, text=PROVIDER_MARKER) for _ in range(3)])
    async with client(lambda _: next(responses)) as gateway:
        for _ in range(4):
            response = await gateway.post(PATH, headers=AUTH, json=observation())
            assert response.status_code == 503
            assert PROVIDER_MARKER not in response.text
    assert int(response.headers["retry-after"]) > 0


async def test_budget_counts_each_attempt_and_survives_gateway_restart(monkeypatch):
    monkeypatch.setenv("REEDLE_DAILY_ATTEMPT_LIMIT", "1")
    calls = []

    def provider(request):
        calls.append(request)
        return httpx.Response(503, headers={"Retry-After": "0"})

    payload = observation()
    async with client(provider) as gateway:
        response = await gateway.post(PATH, headers=AUTH, json=payload)
        assert response.status_code == 429
        assert response.json()["detail"] == "daily_attempt_budget_exhausted"
    async with client(unreachable) as restarted:
        response = await restarted.post(PATH, headers=AUTH, json=observation())
        assert response.status_code == 429
        assert 0 < int(response.headers["retry-after"]) <= 86_400
    assert len(calls) == 1


async def test_gateway_reloads_rotated_credentials_without_logging_them(monkeypatch, caplog):
    credentials = []

    def provider(request):
        credentials.append(request.headers["authorization"])
        return completion(draft())

    caplog.set_level("INFO", logger="uvicorn.error.reedle")
    async with client(provider) as gateway:
        assert (await gateway.post(PATH, headers=AUTH, json=observation())).status_code == 200

    monkeypatch.setenv("BAZE_API_KEY", "rotated-test-provider")
    monkeypatch.setenv("REEDLE_CLIENT_TOKEN", "rotated-test-client")
    async with client(provider) as gateway:
        assert (await gateway.post(PATH, headers=AUTH, json=observation())).status_code == 401
        new_auth = {"Authorization": "Bearer rotated-test-client"}
        assert (await gateway.post(PATH, headers=new_auth, json=observation())).status_code == 200

    assert credentials == ["Bearer test-provider-key", "Bearer rotated-test-provider"]
    for secret in ("test-provider-key", "test-client-token", "rotated-test-provider", "rotated-test-client"):
        assert secret not in caplog.text
