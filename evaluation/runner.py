"""Score tutor responses and replay stricter intervention thresholds."""

import base64
from collections import Counter
from collections.abc import Iterator
from dataclasses import dataclass
from hashlib import sha256
import json
from math import ceil
import os
import re
from time import perf_counter
from typing import Annotated, Any, Literal, Self
from unicodedata import normalize
from uuid import NAMESPACE_URL, uuid4, uuid5

import httpx
from pydantic import Field, model_validator

from server.reedle_server.contract import (
    Decision,
    DraftAction,
    Feedback,
    MAX_BODY_BYTES,
    MAX_ENTITIES,
    MIN_CONFIDENCE,
    MISSING_DRAFT_REASON,
    ObserveRequest,
    Recognition,
    Revision,
    StrictObject,
    Subject,
    Transcript,
    WireUUID,
    parse_json,
)

from .dataset import Case
from .sketches import Box, SIZE


Probability = Annotated[float, Field(ge=0, le=1)]
Index = Annotated[int, Field(ge=0, lt=MAX_ENTITIES)]
Millis = Annotated[float, Field(ge=0)]
Version = Annotated[int, Field(ge=1, le=1)]
REPLY_BYTES_CAP = 65_536
STREAM_BYTES_CAP = 128 * 1_024
STREAM_TIMEOUT_SECONDS = 42
ENDPOINT_PATH = "/v1/tutor/observe"
GLYPHS = str.maketrans({"−": "-", "–": "-", "—": "-", "×": "*", "·": "*", "÷": "/",
                        "²": "^2", "³": "^3", "≤": "<=", "≥": ">=", "°": " degree "})


class Result(StrictObject):
    kind: Subject
    transcript: Transcript
    confidence: Probability
    targets: Annotated[tuple[Index, ...], Field(max_length=MAX_ENTITIES)]
    decision: Decision
    action_targets: Annotated[tuple[Index, ...], Field(max_length=4)] = ()
    model: Annotated[str, Field(min_length=1, max_length=512)] | None = None

    @model_validator(mode="after")
    def ground_actions(self) -> Self:
        if len(set(self.targets)) != len(self.targets):
            raise ValueError("duplicate recognition targets")
        if (self.decision == "act") != bool(self.action_targets) or not set(self.action_targets).issubset(self.targets):
            raise ValueError("intervention must have actions on recognized targets")
        return self


class Record(StrictObject):
    case_id: str
    latency_ms: Millis
    drafting_latency_ms: Millis | None = None
    result: Result | None = None
    error: Annotated[str, Field(pattern=r"^[a-z0-9_]{1,40}$")] | None = None

    @model_validator(mode="after")
    def one_outcome(self) -> Self:
        if (self.result is None) == (self.error is None):
            raise ValueError("record requires a result or an error")
        if self.drafting_latency_ms is not None and self.drafting_latency_ms > self.latency_ms:
            raise ValueError("drafting cannot start after the attempt ends")
        return self


class Replay(StrictObject):
    schema_version: Version = 1
    source: Literal["fixture", "gateway"]
    transport: Literal["json", "sse"] | None = None
    gateway_floor: Probability = MIN_CONFIDENCE
    dataset_fingerprint: Annotated[str, Field(pattern=r"^[a-f0-9]{64}$")] | None = None
    records: list[Record]

    @model_validator(mode="after")
    def require_capture_fingerprint(self) -> Self:
        if self.source == "gateway" and self.dataset_fingerprint is None:
            raise ValueError("gateway replay requires a dataset fingerprint")
        return self


class WireAction(DraftAction):
    action_id: WireUUID = Field(alias="actionId")


class WireDecision(StrictObject):
    schema_version: Version = Field(alias="schemaVersion")
    request_id: WireUUID = Field(alias="requestId")
    note_id: WireUUID = Field(alias="noteId")
    observed_revision: Revision = Field(alias="observedRevision")
    decision: Decision
    actions: Annotated[list[WireAction], Field(max_length=4)]


class WireReply(StrictObject):
    model: Annotated[str, Field(min_length=1, max_length=512)]
    reason: Feedback
    recognition: Recognition
    response: WireDecision


@dataclass(frozen=True)
class Limits:
    max_fpr: float = 0.05
    max_fnr: float = 0.20
    max_p50_ms: float = 2_500
    max_p95_ms: float = 7_000


def _fingerprint_crop(case: Case, png: bytes, boxes: tuple[Box, ...]) -> bytes:
    labels = case.model_dump(mode="json", exclude={"sketch", "image_path", "boxes"})
    data = json.dumps({**labels, "boxes": boxes}, sort_keys=True, separators=(",", ":")).encode("ascii")
    digest = sha256(data)
    digest.update(b"\0")
    digest.update(png)
    return digest.digest()


def request_for(case: Case, png: bytes, boxes: tuple[Box, ...]) -> dict[str, Any]:
    note_id = uuid5(NAMESPACE_URL, f"reedle:tutor-benchmark:{case.id}")
    ids = [str(uuid5(note_id, f"entity-{index}")) for index in range(len(boxes))]
    if case.sketch is not None:
        width, height = SIZE
    else:
        # The external PNG was already validated when it was loaded; IHDR stores its size.
        width, height = int.from_bytes(png[16:20]), int.from_bytes(png[20:24])
    request = ObserveRequest.model_validate({
        "observation": {"schemaVersion": 1, "requestId": str(uuid4()), "noteId": str(note_id),
                        "canvasRevision": 1, "focusBounds": {"x": 0, "y": 0, "width": width, "height": height},
                        "entityIds": ids},
        "image": base64.b64encode(png).decode("ascii"),
        "entities": [dict(zip(("x", "y", "width", "height"), box), id=entity) for entity, box in zip(ids, boxes)],
    })
    return request.model_dump(mode="json", by_alias=True, exclude_unset=True)


def _request_body(case_id: str, payload: dict[str, Any]) -> bytes:
    body = json.dumps(payload, separators=(",", ":")).encode("ascii")
    if len(body) > MAX_BODY_BYTES:
        raise ValueError(f"{case_id} exceeds the gateway request limit")
    return body


def audit_dataset(cases: tuple[Case, ...]) -> dict[str, Any]:
    sources = {case.source for case in cases}
    if len(sources) != 1 or len({case.id for case in cases}) != len(cases):
        raise ValueError("audit requires unique cases from a single dataset source")
    digest = sha256()
    seen: dict[str, str] = {}
    distribution: dict[str, Counter[str]] = {}
    maximum_body = 0
    for case in cases:
        png, boxes = case.crop()
        image_id = sha256(png).hexdigest()
        if image_id in seen:
            raise ValueError(f"{case.id} repeats the image used by {seen[image_id]}")
        seen[image_id] = case.id
        body = _request_body(case.id, request_for(case, png, boxes))
        maximum_body = max(maximum_body, len(body))
        digest.update(_fingerprint_crop(case, png, boxes))
        distribution.setdefault(case.subject, Counter())[case.status] += 1
    return {
        "dataset_source": cases[0].source,
        "dataset_fingerprint": digest.hexdigest(),
        "valid_requests": len(cases),
        "maximum_request_bytes": maximum_body,
        "subjects": {subject: {status: counts[status] for status in ("correct", "partial", "error")}
                     for subject, counts in sorted(distribution.items())},
    }


def _result(raw: bytes | bytearray, observation: dict[str, Any]) -> Result | None:
    reply = WireReply.model_validate(parse_json(raw))
    wire = reply.response
    recognition = reply.recognition
    if (wire.request_id != observation["requestId"] or wire.note_id != observation["noteId"]
            or wire.observed_revision != observation["canvasRevision"]):
        raise ValueError("response observation mismatch")
    if len({action.action_id for action in wire.actions}) != len(wire.actions):
        raise ValueError("duplicate action IDs")
    indices = {uuid: index for index, uuid in enumerate(observation["entityIds"])}
    try:
        targets = tuple(indices[uuid] for uuid in recognition.target_entity_ids)
        action_targets = tuple(indices[action.target_entity_id] for action in wire.actions)
    except KeyError:
        raise ValueError("response contains targets outside the observation") from None
    result = Result(kind=recognition.kind, transcript=recognition.transcript, confidence=recognition.confidence,
                    targets=targets, decision=wire.decision, action_targets=action_targets, model=reply.model)
    if (reply.reason == MISSING_DRAFT_REASON and result.kind == "unknown" and result.transcript == ""
            and result.confidence == 0 and not result.targets and result.decision == "observe_only"):
        return None
    return result


def _endpoint(value: str) -> httpx.URL:
    message = f"live evaluation requires an HTTPS endpoint ending in {ENDPOINT_PATH}"
    try:
        url = httpx.URL(value)
    except httpx.InvalidURL:
        raise ValueError(message) from None
    if (url.scheme != "https" or not url.host or url.raw_path != ENDPOINT_PATH.encode("ascii")
            or url.userinfo or url.fragment or "@" in value.partition("://")[2].partition("/")[0]):
        raise ValueError(message)
    return url


def _read_json_reply(response: httpx.Response) -> bytearray:
    raw = bytearray()
    for chunk in response.iter_bytes(chunk_size=8_192):
        if len(raw) + len(chunk) > REPLY_BYTES_CAP:
            raise ValueError("gateway reply too large")
        raw.extend(chunk)
    return raw


def _stream_events(response: httpx.Response, deadline: float) -> Iterator[tuple[bytes, bytes]]:
    media = response.headers.get("content-type", "").partition(";")[0].strip().lower()
    if media != "text/event-stream":
        raise ValueError("expected the gateway event stream")

    buffer = bytearray()
    lines: list[bytes] = []
    received = 0
    for chunk in response.iter_bytes():
        if perf_counter() > deadline:
            raise TimeoutError
        received += len(chunk)
        if received > STREAM_BYTES_CAP:
            raise ValueError("gateway event stream too large")
        buffer.extend(chunk)
        offset = 0
        while (end := buffer.find(b"\n", offset)) != -1:
            line = bytes(buffer[offset:end]).removesuffix(b"\r")
            offset = end + 1
            if line.startswith(b":"):
                continue
            if line:
                lines.append(line)
                if len(lines) > 2:
                    raise ValueError("invalid gateway event fields")
                continue
            if not lines:
                continue
            # The iPad gateway sends each event with one name and one JSON data line.
            if len(lines) != 2 or not lines[0].startswith(b"event: ") or not lines[1].startswith(b"data: "):
                raise ValueError("invalid gateway event")
            name, data = lines
            lines.clear()
            yield name[7:], data[6:]
        del buffer[:offset]


def _fetch(client: httpx.Client, url: httpx.URL, case: Case, payload: dict[str, Any], body: bytes,
           *, stream: bool) -> Record:
    started = perf_counter()
    drafting_latency = None

    def elapsed_ms() -> float:
        return round((perf_counter() - started) * 1_000, 3)

    def finish(*, result: Result | None = None, error: str | None = None) -> Record:
        return Record(case_id=case.id, latency_ms=elapsed_ms(), drafting_latency_ms=drafting_latency,
                      result=result, error=error)

    try:
        with client.stream("POST", url, content=body) as response:
            if response.status_code != 200:
                return finish(error=f"http_{response.status_code}")
            if response.headers.get("content-encoding", "identity").lower() != "identity":
                raise ValueError("unsupported gateway response encoding")
            if stream:
                reading = False
                for event, data in _stream_events(response, started + STREAM_TIMEOUT_SECONDS):
                    if event == b"progress":
                        progress = parse_json(data)
                        if progress == {"phase": "reading"} and not reading:
                            reading = True
                        elif progress == {"phase": "drafting"} and reading and drafting_latency is None:
                            drafting_latency = elapsed_ms()
                        else:
                            raise ValueError("unexpected gateway progress event")
                    elif event == b"result" and reading:
                        raw = data
                        break
                    elif event == b"error" and reading:
                        error = parse_json(data)
                        status = error.get("status") if isinstance(error, dict) else None
                        if type(status) is not int or not 400 <= status <= 599:
                            raise ValueError("invalid gateway error status")
                        return finish(error=f"http_{status}")
                    else:
                        raise ValueError("unexpected gateway event")
                else:
                    raise ValueError("missing gateway result event")
            else:
                raw = _read_json_reply(response)
            result = _result(raw, payload["observation"])
            return finish(result=result) if result is not None else finish(error="invalid_provider_draft")
    except (httpx.TimeoutException, TimeoutError):
        return finish(error="timeout")
    except httpx.HTTPError:
        return finish(error="transport_error")
    except (ValueError, RecursionError):
        return finish(error="invalid_response")


def live_records(cases: tuple[Case, ...], endpoint: str, *, stream: bool = False,
                 transport: httpx.BaseTransport | None = None) -> Replay:
    url = _endpoint(endpoint)
    token = os.getenv("REEDLE_CLIENT_TOKEN", "")
    if not re.fullmatch(r"[!-~]{1,512}", token):
        raise ValueError("set REEDLE_CLIENT_TOKEN to the gateway client token")
    pending = []
    digest = sha256()
    for case in cases:
        png, boxes = case.crop()
        digest.update(_fingerprint_crop(case, png, boxes))
        payload = request_for(case, png, boxes)
        body = _request_body(case.id, payload)
        pending.append((case, payload, body))
    records = []
    headers = {
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", "Accept-Encoding": "identity",
    }
    if stream:
        headers["Accept"] = "text/event-stream"
    with httpx.Client(transport=transport, timeout=20.0, trust_env=False, follow_redirects=False,
                      headers=headers) as client:
        for case, payload, body in pending:
            record = _fetch(client, url, case, payload, body, stream=stream)
            records.append(record)
            if record.error is not None:
                break
    return Replay(source="gateway", transport="sse" if stream else "json",
                  dataset_fingerprint=digest.hexdigest(), records=records)


def _text(value: str, *, math: bool) -> str:
    value = normalize("NFKC", value.translate(GLYPHS)).strip()
    if math:
        return "".join(value.split()).rstrip(".;")
    return " ".join(re.sub(r"[,:;]", " ", value).split()).rstrip(".").casefold()


def _contains(transcript: str, phrase: str, *, math: bool) -> bool:
    variant = _text(phrase, math=math)
    if not variant:
        return False
    if math:
        # Spaces may vary around symbols. Refuse prefixes of a longer number or expression.
        normalized = normalize("NFKC", transcript.translate(GLYPHS))
        equation = r"\s*".join(map(re.escape, variant))
        pattern = r"(?<!\w)(?<!\d\.)" + equation + r"(?!\w|\.\d|\s*[+*/^=<>-])"
        operators = tuple("+-*/^=<>")
        return any(not normalized[:match.start()].rstrip().endswith(operators)
                   for match in re.finditer(pattern, normalized))
    return re.search(r"(?<!\w)" + re.escape(variant) + r"(?!\w)", _text(transcript, math=False)) is not None


def _score(case: Case, record: Record | None, floor: float) -> dict[str, Any]:
    row: dict[str, Any] = {"id": case.id, "subject": case.subject, "status": case.status,
                           "category": case.category, "expected_act": case.intervene}
    if record is None:
        return {**row, "error": "not_attempted"}
    row["latency_ms"] = record.latency_ms
    if record.drafting_latency_ms is not None:
        row["drafting_latency_ms"] = record.drafting_latency_ms
    if record.result is None:
        return {**row, "error": record.error}
    result = record.result
    is_math = case.subject == "math"
    text = _text(result.transcript, math=is_math)
    type_ok = result.kind == case.subject
    acted = result.decision == "act"
    return {
        **row, "confidence": result.confidence, "acted": acted,
        "kind": result.kind, "type_ok": type_ok,
        "transcript_ok": bool(text) and text in {_text(alias, math=is_math) for alias in case.transcripts},
        "structure_ok": type_ok and all(any(_contains(result.transcript, alias, math=is_math) for alias in group)
                                        for group in case.structure),
        "target_ok": set(case.targets).issubset(result.targets),
        "action_target_ok": set(result.action_targets).issubset(case.targets) if acted else None,
        "gate_violation": acted and (result.confidence < floor or result.kind == "unknown"),
    }


def _ratio(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def _matrix(rows: list[dict[str, Any]], threshold: float | None = None) -> dict[str, int | float | None]:
    counts: Counter[str] = Counter()
    for row in rows:
        if "acted" not in row:
            continue
        predicted = row["acted"] and (threshold is None or (row["confidence"] >= threshold and row["kind"] != "unknown"))
        expected = row["expected_act"]
        counts[{(True, True): "tp", (False, False): "tn", (True, False): "fp", (False, True): "fn"}[predicted, expected]] += 1
    tp, tn, fp, fn = (counts[key] for key in ("tp", "tn", "fp", "fn"))
    return {"tp": tp, "tn": tn, "fp": fp, "fn": fn, "fpr": _ratio(fp, fp + tn), "fnr": _ratio(fn, fn + tp)}


def _percentiles(values: list[float]) -> dict[str, float | None]:
    values = sorted(values)
    return {name: values[ceil(len(values) * quantile) - 1] if values else None
            for name, quantile in (("p50", 0.50), ("p95", 0.95))}


def _aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    valid = [row for row in rows if "acted" in row]
    attempts = [row["latency_ms"] for row in rows if "latency_ms" in row]
    acted = [row for row in valid if row["acted"]]
    drafting = [row["drafting_latency_ms"] for row in valid if "drafting_latency_ms" in row]
    errors = Counter(row["error"] for row in rows if "error" in row and row["error"] != "not_attempted")
    return {
        "cases": len(rows), "attempted": len(attempts), "valid": len(valid), "errors": sum(errors.values()),
        "error_counts": dict(errors), "coverage": _ratio(len(valid), len(rows)),
        "type_accuracy": _ratio(sum(row["type_ok"] for row in valid), len(valid)),
        "transcript_accuracy": _ratio(sum(row["transcript_ok"] for row in valid), len(valid)),
        "structure_accuracy": _ratio(sum(row["structure_ok"] for row in valid), len(valid)),
        "target_accuracy": _ratio(sum(row["target_ok"] for row in valid), len(valid)),
        "action_target_accuracy": _ratio(sum(row["action_target_ok"] for row in acted), len(acted)),
        "intervention": _matrix(valid), "gate_violations": sum(row["gate_violation"] for row in valid),
        "latency_ms": _percentiles([row["latency_ms"] for row in valid]),
        "drafting_responses": len(drafting), "drafting_latency_ms": _percentiles(drafting),
        "attempt_latency_ms": _percentiles(attempts),
    }


def _within_budget(matrix: dict[str, Any], limits: Limits) -> bool:
    fpr, fnr = matrix["fpr"], matrix["fnr"]
    return fpr is not None and fnr is not None and fpr <= limits.max_fpr and fnr <= limits.max_fnr


def build_report(cases: tuple[Case, ...], replay: Replay, limits: Limits = Limits()) -> dict[str, Any]:
    sources = {case.source for case in cases}
    ids = {case.id for case in cases}
    records = {record.case_id: record for record in replay.records}
    if len(sources) != 1 or len(ids) != len(cases):
        raise ValueError("evaluation requires one nonempty dataset with unique IDs")
    if len(records) != len(replay.records) or not records.keys() <= ids:
        raise ValueError("replay has duplicate or unknown case IDs")
    digest = sha256()
    for case in cases:
        png, boxes = case.crop()
        digest.update(_fingerprint_crop(case, png, boxes))
        record = records.get(case.id)
        if record is not None and record.result is not None and max(record.result.targets, default=-1) >= len(boxes):
            raise ValueError(f"replay has an out-of-range target for {case.id}")
    fingerprint = digest.hexdigest()
    if replay.dataset_fingerprint is not None and replay.dataset_fingerprint != fingerprint:
        raise ValueError("replay fingerprint does not match the dataset")
    rows = [_score(case, records.get(case.id), replay.gateway_floor) for case in cases]
    groups = {subject: [row for row in rows if row["subject"] == subject] for subject in sorted({case.subject for case in cases})}
    subjects = {subject: _aggregate(group) for subject, group in groups.items()}
    overall = _aggregate(rows)
    complete = overall["valid"] == len(cases)
    sweep = []
    recommendation = None
    for threshold in sorted({replay.gateway_floor, *(cutoff for cutoff in (0.85, 0.90, 0.95, 0.98, 1.0)
                                                     if cutoff > replay.gateway_floor)}):
        matrices = {subject: _matrix(group, threshold) for subject, group in groups.items()}
        sweep.append({"threshold": threshold, "subjects": matrices, "overall": _matrix(rows, threshold)})
        if (recommendation is None and complete and overall["gate_violations"] == 0
                and all(_within_budget(matrix, limits) for matrix in matrices.values())):
            recommendation = threshold
    return {
        "source": replay.source, "transport": replay.transport, "dataset_source": cases[0].source,
        "dataset_fingerprint": fingerprint,
        "models": sorted({record.result.model for record in records.values() if record.result and record.result.model}),
        "gateway_floor": replay.gateway_floor, "scope_complete": complete,
        "limits": {"fpr": limits.max_fpr, "fnr": limits.max_fnr, "p50_ms": limits.max_p50_ms, "p95_ms": limits.max_p95_ms},
        "latency_budget_met": complete and all(metrics["latency_ms"]["p50"] <= limits.max_p50_ms
                                               and metrics["latency_ms"]["p95"] <= limits.max_p95_ms
                                               for metrics in subjects.values()),
        "recommended_threshold": recommendation, "overall": overall, "subjects": subjects,
        "threshold_sweep": sweep, "cases": rows,
    }
