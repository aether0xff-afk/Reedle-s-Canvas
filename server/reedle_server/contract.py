import base64
import binascii
from hashlib import sha256
from io import BytesIO
import json
import re
from struct import error as StructError, unpack_from
from typing import Annotated, Any, Literal, Self, get_args
from unicodedata import normalize
from uuid import UUID, uuid5
import zlib

from PIL import Image
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, model_validator


MAX_BODY_BYTES = 750_000
MAX_PNG_BYTES = 512 * 1024
MAX_PNG_SIDE = 1_280
MAX_ENTITIES = 128
MIN_CONFIDENCE = 0.82
MISSING_DRAFT_REASON = "이번에는 필기를 확인하기 어려웠어요."
EDGE_TOLERANCE = 1e-9

Subject = Literal["math", "text", "chemistry", "physics", "unknown"]
Decision = Literal["observe_only", "act"]
Placement = Literal["near_right", "near_left", "above", "below", "on_target"]
TextAction = Literal["annotate", "write", "ask_question"]
DrawContent = Literal["arrow", "underline", "circle", "diagram:triangle", "diagram:rectangle",
                      "plot:line", "plot:parabola", "plot:sine"]

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_CRITICAL = {b"IHDR", b"PLTE", b"IDAT", b"IEND"}
CODE_IN_ACTION = re.compile(
    r"`|</?(?:script|iframe|html)\b|\b(?:print|console\.log|exec|eval|__import__|os\.system)\s*\("
    r"|\b(?:def|function)\s+\w+\s*\(|\b(?:let|var|const)\s+\w+\s*="
    r"|^\s*(?:from\s+[\w.]+\s+import|import|rm|sudo|curl|wget|python|node|powershell|cmd|del)\s+",
    re.IGNORECASE | re.MULTILINE,
)


class ImageTooLarge(ValueError):
    pass


def parse_json(data: str | bytes | bytearray) -> Any:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ValueError("duplicate JSON field")
        return result

    def invalid_constant(_: str) -> Any:
        raise ValueError("nonfinite JSON number")

    if not isinstance(data, str):
        data = data.decode("utf-8")
    return json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid_constant)


def _canonical_uuid(text: str) -> str:
    canonical = str(UUID(text))
    if canonical != text.lower():
        raise ValueError("UUID must use the hyphenated representation")
    return canonical


def _bounded_text(value: str, limit: int) -> str:
    if len(value.encode("utf-8")) > limit:
        raise ValueError("text exceeds the UTF-8 byte limit")
    if any(not character.isprintable() and character not in "\n\t" for character in value):
        raise ValueError("text contains a control character")
    return value


WireUUID = Annotated[str, AfterValidator(_canonical_uuid)]
Revision = Annotated[int, Field(ge=0, le=2**63 - 1)]
Transcript = Annotated[str, AfterValidator(lambda text: _bounded_text(text, 1_024))]
Feedback = Annotated[str, AfterValidator(lambda text: _bounded_text(text, 512))]


class StrictObject(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", allow_inf_nan=False)


class Bounds(StrictObject):
    x: float
    y: float
    width: Annotated[float, Field(gt=0)]
    height: Annotated[float, Field(gt=0)]


class CropEntity(Bounds):
    id: WireUUID

    @model_validator(mode="after")
    def inside_crop(self) -> Self:
        if (self.x < 0 or self.y < 0 or self.x > 1 or self.y > 1 or self.width > 1 or self.height > 1
                or self.x + self.width > 1 + EDGE_TOLERANCE or self.y + self.height > 1 + EDGE_TOLERANCE):
            raise ValueError("entity must lie in the crop")
        return self


class Observation(StrictObject):
    schema_version: Annotated[int, Field(alias="schemaVersion", ge=1, le=1)]
    request_id: WireUUID = Field(alias="requestId")
    note_id: WireUUID = Field(alias="noteId")
    canvas_revision: Revision = Field(alias="canvasRevision")
    focus_bounds: Bounds = Field(alias="focusBounds")
    entity_ids: Annotated[list[WireUUID], Field(alias="entityIds", min_length=1, max_length=MAX_ENTITIES)]


class RecentEvent(StrictObject):
    revision: Revision
    kind: Subject
    transcript: Transcript
    feedback: Feedback
    offered_hint: bool | None = Field(default=None, alias="offeredHint")


class ObserveRequest(StrictObject):
    observation: Observation
    image: str
    entities: Annotated[list[CropEntity], Field(min_length=1, max_length=MAX_ENTITIES)]
    recent: Annotated[list[RecentEvent], Field(max_length=3)] = Field(default_factory=list)

    @model_validator(mode="after")
    def match_observation(self) -> Self:
        observed = set(self.observation.entity_ids)
        entities = {entity.id for entity in self.entities}
        if observed != entities or len(observed) != len(self.observation.entity_ids) or len(entities) != len(self.entities):
            raise ValueError("the observation and crop must contain the same unique entities")
        if any(event.revision >= self.observation.canvas_revision for event in self.recent):
            raise ValueError("history must be from earlier canvas revisions")
        return self

    def fingerprint(self, png: bytes) -> bytes:
        metadata = self.model_dump(mode="json", by_alias=True, exclude={"image"})
        digest = sha256(json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        digest.update(png)
        return digest.digest()


def verified_png(encoded: str) -> bytes:
    if len(encoded) > 4 * ((MAX_PNG_BYTES + 2) // 3):
        raise ImageTooLarge
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("invalid base64") from None
    if len(data) > MAX_PNG_BYTES:
        raise ImageTooLarge
    if len(data) < 33 or not data.startswith(PNG_SIGNATURE + b"\0\0\0\rIHDR"):
        raise ValueError("invalid PNG header")
    width, height = unpack_from(">II", data, 16)
    if max(width, height) > MAX_PNG_SIDE:
        raise ImageTooLarge

    _verify_png_chunks(data)
    try:
        with Image.open(BytesIO(data), formats=["PNG"]) as image:
            image.load()
    except (OSError, ValueError, SyntaxError, StructError, Image.DecompressionBombError):
        raise ValueError("invalid PNG data") from None
    return data


def _verify_png_chunks(data: bytes) -> None:
    # Pillow decodes the image. Check framing separately so a valid image cannot carry a trailing payload.
    position = len(PNG_SIGNATURE)
    view = memoryview(data)
    while position + 12 <= len(data):
        length, kind = unpack_from(">I4s", data, position)
        checksum_at = position + 8 + length
        end = checksum_at + 4
        if end > len(data) or not kind.isalpha() or not kind[2:3].isupper() or kind == b"acTL":
            break
        if (kind[:1].isupper() and kind not in PNG_CRITICAL) or (kind == b"IHDR" and position != len(PNG_SIGNATURE)):
            break
        checksum, = unpack_from(">I", data, checksum_at)
        if zlib.crc32(view[position + 4 : checksum_at]) != checksum:
            break
        if kind == b"IEND" and length == 0 and end == len(data):
            return
        if kind == b"IEND":
            break
        position = end
    raise ValueError("invalid PNG chunks")


class Recognition(StrictObject):
    kind: Subject
    transcript: Transcript
    confidence: Annotated[float, Field(ge=0, le=1)]
    target_entity_ids: Annotated[list[WireUUID], Field(alias="targetEntityIds", max_length=MAX_ENTITIES)]


class DraftAction(StrictObject):
    type: TextAction | Literal["draw"]
    target_entity_id: WireUUID = Field(alias="targetEntityId")
    placement_intent: Placement = Field(alias="placementIntent")
    content: Annotated[str, Field(min_length=1, max_length=2_000)]

    @model_validator(mode="after")
    def allowed_content(self) -> Self:
        if self.type == "draw":
            if self.content not in get_args(DrawContent):
                raise ValueError("unsupported drawing")
        elif not _bounded_text(self.content, 8_000).strip() or CODE_IN_ACTION.search(self.content):
            raise ValueError("action content must be plain pedagogic text")
        return self


class ProviderDraft(StrictObject):
    reason: Feedback
    recognition: Recognition
    decision: Decision
    actions: Annotated[list[DraftAction], Field(max_length=4)]

    @model_validator(mode="after")
    def ground_actions(self) -> Self:
        targets = set(self.recognition.target_entity_ids)
        if len(targets) != len(self.recognition.target_entity_ids):
            raise ValueError("recognition targets must be unique")
        if (self.decision == "act") != bool(self.actions):
            raise ValueError("actions must match the decision")
        if any(action.target_entity_id not in targets for action in self.actions):
            raise ValueError("actions must anchor to recognized entities")
        if not self.reason.strip():
            raise ValueError("a brief reason is required")
        return self


def bind_reply(request: ObserveRequest, model: str, content: str | None) -> dict[str, Any]:
    observation = request.observation
    reason = MISSING_DRAFT_REASON
    recognition = Recognition(kind="unknown", transcript="", confidence=0.0, targetEntityIds=[])
    actions: list[dict[str, Any]] = []

    if content is not None:
        draft = _read_draft(content, observation)
        if draft is not None:
            recognition = draft.recognition
            if recognition.confidence < MIN_CONFIDENCE or recognition.kind == "unknown":
                reason = "필기를 확실히 읽기 어려워 제안을 보류했어요."
            elif draft.actions and _already_hinted(request.recent, recognition):
                reason = "같은 풀이에 앞서 제안한 힌트가 있어요."
            else:
                reason = draft.reason
                actions = [
                    {**action.model_dump(mode="json", by_alias=True),
                     "actionId": str(uuid5(UUID(observation.request_id), f"tutor-action:{index}"))}
                    for index, action in enumerate(draft.actions)
                ]

    return {
        "model": model,
        "reason": reason,
        "recognition": recognition.model_dump(mode="json", by_alias=True),
        "response": {
            "schemaVersion": 1,
            "requestId": observation.request_id,
            "noteId": observation.note_id,
            "observedRevision": observation.canvas_revision,
            "decision": "act" if actions else "observe_only",
            "actions": actions,
        },
    }


def _already_hinted(recent: list[RecentEvent], current: Recognition) -> bool:
    latest = max(recent, key=lambda event: event.revision, default=None)
    if latest is None or not latest.offered_hint or latest.kind != current.kind:
        return False

    def written_form(text: str) -> str:
        value = "".join(normalize("NFKC", text).split())
        if current.kind == "math":
            value = value.translate(str.maketrans("−×÷", "-*/"))
        return value

    observed = written_form(current.transcript)
    return bool(observed) and observed == written_form(latest.transcript)


def _read_draft(content: str, observation: Observation) -> ProviderDraft | None:
    try:
        draft = ProviderDraft.model_validate(parse_json(content))
    except (ValueError, RecursionError):
        return None
    if not set(draft.recognition.target_entity_ids).issubset(observation.entity_ids):
        return None
    return draft
