"""Exercise the Swift client and local FastAPI server over HTTP with a test vision provider."""

from base64 import b64encode
import asyncio
import json
from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile
from threading import Thread
import time

import httpx
from PIL import Image, ImageDraw
import uvicorn


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
from reedle_server.app import create_app


def draw_fixture(path, expression):
    image = Image.new("RGB", (240, 150), "white")
    ImageDraw.Draw(image).text((24, 46), expression, fill="black")
    image.save(path)
    return "data:image/png;base64," + b64encode(path.read_bytes()).decode("ascii")


class TestCompletionStream(httpx.AsyncByteStream):
    def __init__(self, folder, draft=None, *, wait_for_client=False):
        self.folder = folder
        self.draft = draft
        self.wait_for_client = wait_for_client

    @staticmethod
    def frame(delta, finish=None):
        choice = {"index": 0, "delta": delta, "finish_reason": finish}
        return ("data: " + json.dumps({"choices": [choice]}, ensure_ascii=False) + "\n\n").encode()

    async def __aiter__(self):
        yield self.frame({"role": "assistant"})
        if self.draft is None:
            yield self.frame({"content": '{"reason":"답변이 완성되기 전'})
            (self.folder / "upstream-started").touch()
            try:
                await asyncio.Future()
            except asyncio.CancelledError:
                (self.folder / "upstream-cancelled").touch()
                raise
            return

        content = json.dumps(self.draft, ensure_ascii=False)
        split = content.index(self.draft["reason"]) + 2
        first = self.frame({"content": content[:split]})
        for start in range(0, len(first), 13):
            yield first[start:start + 13]
        if self.wait_for_client:
            while not (self.folder / "client-drafting").exists():
                await asyncio.sleep(0.02)
        yield self.frame({"content": content[split:]})
        yield self.frame({}, "stop")
        yield b"data: [DONE]\n\n"


def main():
    with tempfile.TemporaryDirectory(prefix="reedle-round-trip-") as scratch:
        folder = Path(scratch)
        wrong = draw_fixture(folder / "wrong.png", "2+2=5")
        corrected = draw_fixture(folder / "corrected.png", "2+2=4")
        slow = draw_fixture(folder / "slow.png", "2+2=4, delay")
        failing = draw_fixture(folder / "failing.png", "2+2=4, unavailable")
        seen = []
        failed_attempts = 0

        async def provider(request):
            nonlocal failed_attempts
            assert request.headers["authorization"] == "Bearer local-test-provider"
            assert request.url.path == "/v1/gateway/chat/completions/"
            model_input = request.content.decode("utf-8")
            streaming = json.loads(request.content)["stream"]
            if slow in model_input:
                assert streaming
                return httpx.Response(200, stream=TestCompletionStream(folder),
                                      headers={"Content-Type": "text/event-stream"})
            if failing in model_input:
                failed_attempts += 1
                return httpx.Response(503, headers={"Retry-After": "0"})
            if wrong in model_input:
                symbol, transcript, feedback = 5, "2+2=5", "다시 계산해 볼래?"
            else:
                assert corrected in model_input and "2+2=5" in model_input
                symbol, transcript, feedback = 4, "2+2=4", "수정한 계산이 맞아요."
            entity = f"10000000-0000-4000-8000-00000000000{symbol}"
            assert entity in model_input.lower()
            seen.append(symbol)
            actions = [
                {"type": "draw", "targetEntityId": entity, "placementIntent": "on_target", "content": "circle"},
                {"type": "ask_question", "targetEntityId": entity, "placementIntent": "near_right", "content": feedback},
            ] if symbol == 5 else []
            draft = {
                "recognition": {"kind": "math", "transcript": transcript, "confidence": 0.97,
                                "targetEntityIds": [entity]},
                "reason": feedback, "decision": "act" if actions else "observe_only", "actions": actions,
            }
            if streaming:
                return httpx.Response(200, stream=TestCompletionStream(folder, draft, wait_for_client=True),
                                      headers={"Content-Type": "text/event-stream"})
            return httpx.Response(200, json={
                "choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": json.dumps(draft)}}],
                "usage": {"prompt_tokens": 120, "completion_tokens": 50, "total_tokens": 170},
            })

        os.environ.update(REEDLE_CLIENT_TOKEN="local-test-access", BAZE_API_KEY="local-test-provider",
                          BAZE_MODEL="fixture-vision", BAZE_BASE_URL="https://fixture.invalid/v1/gateway",
                          REEDLE_BUDGET_DB=str(folder / "attempts.sqlite3"), REEDLE_DAILY_ATTEMPT_LIMIT="6",
                          REEDLE_PROVIDER_MAX_ATTEMPTS="2", REEDLE_PROVIDER_TIMEOUT_SECONDS="7",
                          REEDLE_REPLY_CACHE_SECONDS="300")
        app = create_app(provider_transport=httpx.MockTransport(provider))
        with socket.socket() as listener, socket.socket() as offline:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            offline.bind(("127.0.0.1", 0))
            offline_port = offline.getsockname()[1]
            server = uvicorn.Server(uvicorn.Config(app, access_log=False, log_level="warning"))
            runner = Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
            runner.start()
            try:
                deadline = time.monotonic() + 8
                while not server.started:
                    if not runner.is_alive() or time.monotonic() >= deadline:
                        raise RuntimeError("The local test gateway did not start.")
                    time.sleep(0.05)
                sources = ["CanvasCamera", "NoteStore", "StrokeOrder", "TutorActions", "TutorMath", "TutorCapture", "TutorGateway",
                           "TutorPlacement", "NoteResource", "PracticeEngine"]
                (folder / "sqlite-shim.h").write_text("#include <sqlite3.h>\n", encoding="utf-8")
                (folder / "module.modulemap").write_text(
                    'module SQLite3 [system] { header "sqlite-shim.h" link "sqlite3" export * }\n', encoding="utf-8"
                )
                binary = folder / "round-trip"
                subprocess.run(["swiftc", "-swift-version", "5", "-I", str(folder), "-O",
                                *(str(ROOT / "ReedlesCanvas" / f"{name}.swift") for name in sources),
                                str(ROOT / "tools/tutor_round_trip.swift"), "-o", str(binary)], check=True)
                subprocess.run([str(binary), f"http://127.0.0.1:{port}/v1/tutor/observe", str(folder),
                                f"http://127.0.0.1:{offline_port}/v1/tutor/observe"], check=True, timeout=35)
                assert seen == [5, 5, 4], "Replaying a request must not call the provider again."
                assert failed_attempts == 2, "The unavailable provider should receive one bounded retry."
            finally:
                server.should_exit = True
                runner.join(timeout=8)


if __name__ == "__main__":
    main()
