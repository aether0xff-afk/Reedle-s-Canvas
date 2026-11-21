import asyncio
import json
from collections import Counter
from pathlib import Path

import httpx
import pytest

from server.reedle_server.app import create_app
from server.reedle_server.contract import MAX_BODY_BYTES, ObserveRequest, bind_reply, verified_png

from evaluation.dataset import load_manifest, synthetic_cases, write_manifest
from evaluation.runner import Limits, Record, Replay, audit_dataset, build_report, live_records, request_for


FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "smoke.json"


def test_benchmark_has_twenty_cases_per_subject_and_nonleaking_requests():
    cases = synthetic_cases()
    assert Counter(case.subject for case in cases) == {"math": 20, "chemistry": 20, "physics": 20}
    assert len({case.id for case in cases}) == 60
    assert all(
        {case.status for case in cases if case.subject == subject} == {"correct", "partial", "error"}
        for subject in ("math", "chemistry", "physics")
    )

    pngs = set()
    for case in cases:
        png, boxes = case.crop()
        assert case.crop() == (png, boxes)
        payload = request_for(case, png, boxes)
        validated = ObserveRequest.model_validate(payload)
        assert verified_png(validated.image) == png
        assert len(json.dumps(payload).encode()) < MAX_BODY_BYTES
        assert set(payload) == {"observation", "image", "entities"}
        assert len({validated.observation.request_id, validated.observation.note_id, *validated.observation.entity_ids}) == 2 + len(boxes)
        assert request_for(case, png, boxes)["observation"]["requestId"] != validated.observation.request_id
        assert set(case.targets) <= set(range(len(boxes)))
        pngs.add(png)
    assert len(pngs) == 60


def test_manifest_round_trip_preserves_annotations_and_crops(tmp_path):
    chosen = synthetic_cases()[:2]
    manifest = write_manifest(tmp_path, chosen)
    loaded = load_manifest(manifest)
    assert [(case.id, case.status, case.answer, case.transcripts, case.targets, case.crop()) for case in loaded] == [
        (case.id, case.status, case.answer, case.transcripts, case.targets, case.crop()) for case in chosen
    ]
    data = json.loads(manifest.read_text(encoding="utf-8"))
    data["source"] = "anonymized-handwriting"
    data["cases"][0]["targets"] = [8]
    manifest.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(ValueError, match="target index"):
        load_manifest(manifest)


def test_audit_checks_real_png_payloads_and_refuses_duplicate_images(tmp_path):
    manifest = write_manifest(tmp_path, synthetic_cases()[:3])
    cases = load_manifest(manifest)
    report = audit_dataset(cases)
    assert report["valid_requests"] == 3
    assert sum(report["subjects"]["math"].values()) == 3
    assert 0 < report["maximum_request_bytes"] < MAX_BODY_BYTES
    assert report["dataset_fingerprint"] == build_report(cases, Replay(source="fixture", records=[]))["dataset_fingerprint"]
    duplicate = cases[1].model_copy(update={"image_path": cases[0].image_path})
    with pytest.raises(ValueError, match="repeats the image"):
        audit_dataset((cases[0], duplicate))


def test_replay_measures_type_text_structure_targets_and_intervention_separately():
    report = build_report(synthetic_cases(), Replay.model_validate_json(FIXTURE.read_text(encoding="utf-8")))
    math = report["subjects"]["math"]
    assert math["cases"] == 20
    assert math["valid"] == 4
    assert math["type_accuracy"] == 1
    assert math["transcript_accuracy"] == 0.75
    assert math["structure_accuracy"] == 1
    assert math["target_accuracy"] == 1
    assert math["intervention"] == {"tp": 1, "tn": 2, "fp": 1, "fn": 0, "fpr": 1 / 3, "fnr": 0}
    assert math["latency_ms"]["p50"] == 1_100
    assert math["latency_ms"]["p95"] == 1_800
    assert report["recommended_threshold"] is None
    assert report["scope_complete"] is False


def test_complete_replay_recommends_lowest_threshold_meeting_each_subject_limits():
    replay = Replay.model_validate_json(FIXTURE.read_text(encoding="utf-8"))
    chosen = tuple(case for case in synthetic_cases() if case.id in {record.case_id for record in replay.records})
    report = build_report(chosen, replay, Limits(max_p95_ms=1_000))
    assert report["scope_complete"] is True
    assert report["latency_budget_met"] is False
    assert report["recommended_threshold"] == 0.90
    assert report["threshold_sweep"][0]["subjects"]["math"]["fp"] == 1
    assert report["threshold_sweep"][2]["subjects"]["math"]["fp"] == 0


def test_failed_result_reduces_coverage_without_counting_as_a_negative():
    case = next(case for case in synthetic_cases() if case.id == "math-02")
    replay = Replay(source="fixture", records=[Record(case_id=case.id, latency_ms=61, error="timeout")])
    report = build_report((case,), replay)
    assert report["overall"]["valid"] == 0
    assert report["overall"]["errors"] == 1
    assert report["overall"]["intervention"]["fn"] == 0
    assert report["overall"]["intervention"]["fnr"] is None
    assert report["overall"]["latency_ms"]["p95"] is None
    assert report["overall"]["attempt_latency_ms"]["p95"] == 61


def test_replay_scores_the_written_wrong_answer_without_substituting_the_correction():
    case = next(case for case in synthetic_cases() if case.id == "math-02")
    replay = Replay.model_validate_json('''{
        "source": "fixture", "records": [{"case_id": "math-02", "latency_ms": 60, "result": {
            "kind": "math", "transcript": "2+2=4", "confidence": 0.99, "targets": [1], "decision": "observe_only"
        }}]
    }''')
    report = build_report((case,), replay)
    assert report["overall"]["type_accuracy"] == 1
    assert report["overall"]["transcript_accuracy"] == 0
    assert report["overall"]["structure_accuracy"] == 0
    assert report["overall"]["intervention"]["fn"] == 1


def test_structure_requires_the_complete_equation():
    case = next(case for case in synthetic_cases() if case.id == "math-03")
    replay = Replay.model_validate_json('''{
        "source": "fixture", "records": [{"case_id": "math-03", "latency_ms": 60, "result": {
            "kind": "math", "transcript": "I read 6 * 7 = 42 + 8.", "confidence": 0.99,
            "targets": [1], "decision": "observe_only"
        }}]
    }''')
    assert build_report((case,), replay)["overall"]["structure_accuracy"] == 0


@pytest.mark.parametrize("endpoint", ["http://localhost/v1/tutor/observe", "https://a.test/other", "https://user@a.test/v1/tutor/observe", "https://a.test/v1/tutor/observe?x=1"])
def test_live_rejects_endpoints_outside_https_observe_contract(endpoint, monkeypatch):
    monkeypatch.delenv("REEDLE_CLIENT_TOKEN", raising=False)
    with pytest.raises(ValueError, match="HTTPS"):
        live_records(synthetic_cases()[:1], endpoint)


def test_live_validates_echoed_revision_and_stops_on_rejected_response(monkeypatch):
    monkeypatch.setenv("REEDLE_CLIENT_TOKEN", "isolated-test-token")

    def respond(request):
        assert request.headers["Authorization"] == "Bearer isolated-test-token"
        observation = json.loads(request.content)["observation"]
        return httpx.Response(200, json={
            "model": "fixture",
            "reason": "Example",
            "recognition": {"kind": "math", "transcript": "2+2=5", "confidence": 0.99,
                            "targetEntityIds": observation["entityIds"][-1:]},
            "response": {"schemaVersion": 1, "requestId": observation["requestId"],
                         "noteId": observation["noteId"], "observedRevision": 0,
                         "decision": "observe_only", "actions": []},
        })

    result = live_records(synthetic_cases()[:2], "https://example.test/v1/tutor/observe",
                          transport=httpx.MockTransport(respond))
    assert len(result.records) == 1
    assert result.records[0].error == "invalid_response"


def test_live_counts_gateway_fallback_as_a_failed_attempt(monkeypatch):
    monkeypatch.setenv("REEDLE_CLIENT_TOKEN", "isolated-test-token")

    def respond(request):
        observation = ObserveRequest.model_validate_json(request.content)
        return httpx.Response(200, json=bind_reply(observation, "fixture", None))

    cases = synthetic_cases()[:2]
    capture = live_records(cases, "https://example.test/v1/tutor/observe",
                           transport=httpx.MockTransport(respond))
    report = build_report(cases, capture)
    assert [record.error for record in capture.records] == ["invalid_provider_draft"]
    assert report["overall"]["valid"] == 0
    assert report["overall"]["intervention"]["tn"] == 0
    assert report["cases"][1]["error"] == "not_attempted"


@pytest.mark.parametrize(("events", "expected"), [
    (b"event: progress\r\ndata: {\"phase\":\"reading\"}\r\n\r\n"
     b": keep-alive\r\n\r\nevent: error\r\ndata: {\"status\":429,\"retryAfter\":10}\r\n\r\n", "http_429"),
    (b"event: progress\ndata: {\"phase\":\"drafting\"}\n\n", "invalid_response"),
    (b"event: progress\ndata: {\"phase\":\"reading\"}\n\n"
     b"event: error\ndata: {\"status\":429,\"retryAfter\":10}\n", "invalid_response"),
])
def test_live_stream_records_errors_and_requires_complete_ordered_events(monkeypatch, events, expected):
    monkeypatch.setenv("REEDLE_CLIENT_TOKEN", "isolated-test-token")

    def respond(request):
        assert request.headers["Accept"] == "text/event-stream"
        # Split the status and line endings across chunks to exercise streaming, not joined JSON.
        return httpx.Response(200, headers={"Content-Type": "text/event-stream"},
                              content=(events[start:start + 11] for start in range(0, len(events), 11)))

    capture = live_records(synthetic_cases()[:1], "https://example.test/v1/tutor/observe",
                           stream=True, transport=httpx.MockTransport(respond))
    assert capture.records[0].error == expected


@pytest.mark.parametrize("stream", [False, True])
def test_low_confidence_with_a_mocked_provider_abstains_through_the_gateway(monkeypatch, tmp_path, stream):
    config = {
        "REEDLE_CLIENT_TOKEN": "isolated-test-token",
        "BAZE_API_KEY": "isolated-provider-key",
        "BAZE_MODEL": "fixture-vision-model",
        "BAZE_BASE_URL": "https://mock.provider.test/v1/gateway",
        "REEDLE_BUDGET_DB": str(tmp_path / "budget.sqlite3"),
        "REEDLE_DAILY_ATTEMPT_LIMIT": "1",
        "REEDLE_PROVIDER_TIMEOUT_SECONDS": "7",
        "REEDLE_PROVIDER_MAX_ATTEMPTS": "1",
        "REEDLE_PROVIDER_MAX_OUTPUT_TOKENS": "1200",
    }
    for name, value in config.items():
        monkeypatch.setenv(name, value)

    def provider(request):
        sent = json.loads(request.content)
        assert sent["stream"] is stream
        context, image = sent["messages"][-1]["content"]
        targets = [entity["id"] for entity in json.loads(context["text"])["entities"]]
        assert verified_png(image["image_url"]["url"].removeprefix("data:image/png;base64,"))
        draft = {
            "reason": "예제 답변",
            "recognition": {"kind": "math", "transcript": "2+2=5", "confidence": 0.81999, "targetEntityIds": targets[1:]},
            "decision": "act",
            "actions": [{"type": "ask_question", "targetEntityId": targets[1], "placementIntent": "below",
                         "content": "다시 한번 더해 볼까요?"}],
        }
        if stream:
            event = {"choices": [{"index": 0, "finish_reason": "stop", "delta": {
                "role": "assistant", "content": json.dumps(draft),
            }}]}
            return httpx.Response(200, content=f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n",
                                  headers={"Content-Type": "text/event-stream"})
        return httpx.Response(200, json={"choices": [{"finish_reason": "stop", "message": {
            "role": "assistant", "content": json.dumps(draft),
        }}]})

    cases = (synthetic_cases()[1],)
    app = create_app(provider_transport=httpx.MockTransport(provider))

    async def through_gateway(request):
        async with app.router.lifespan_context(app), httpx.AsyncClient(
            base_url="https://example.test", transport=httpx.ASGITransport(app=app),
        ) as gateway:
            response = await gateway.post(request.url.path, headers=request.headers, content=request.content)
            return httpx.Response(response.status_code, headers=response.headers, content=response.content)

    transport = httpx.MockTransport(lambda request: asyncio.run(through_gateway(request)))
    capture = live_records(cases, "https://example.test/v1/tutor/observe", stream=stream, transport=transport)

    report = build_report(cases, capture)
    assert report["transport"] == ("sse" if stream else "json")
    assert report["models"] == ["fixture-vision-model"]
    assert report["cases"][0]["confidence"] == 0.81999
    assert report["cases"][0]["acted"] is False
    assert report["overall"]["transcript_accuracy"] == 1
    assert report["overall"]["gate_violations"] == 0
    assert report["overall"]["intervention"]["fn"] == 1
    assert report["overall"]["drafting_responses"] == int(stream)
    if stream:
        assert 0 <= report["cases"][0]["drafting_latency_ms"] <= report["cases"][0]["latency_ms"]

    changed = cases[0].model_copy(update={"status": "partial"})
    with pytest.raises(ValueError, match="fingerprint"):
        build_report((changed,), capture)
