"""Validate example contracts and the most important rejected tutor commands.

Run with: python tools/validate_contracts.py (requires jsonschema).
"""

import copy
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


def validate(schema_name, value):
    schema = load(f"contracts/{schema_name}-v1.schema.json")
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(value)


def binding_errors(canvas, observation, response):
    """Checks that JSON Schema cannot express across three independent messages."""
    errors = []
    if observation["noteId"] != canvas["noteId"] or response["noteId"] != canvas["noteId"]:
        errors.append("note mismatch")
    if observation["requestId"] != response["requestId"]:
        errors.append("request mismatch")
    if observation["canvasRevision"] != canvas["revision"] or response["observedRevision"] != canvas["revision"]:
        errors.append("stale revision")
    user_ids = [ink["id"] for ink in canvas["userInk"]]
    overlay_ids = [item["id"] for item in canvas["aiOverlay"]]
    action_ids = [item["actionId"] for item in response["actions"]]
    if len(user_ids + overlay_ids) != len(set(user_ids + overlay_ids)):
        errors.append("duplicate entity ID")
    if len(action_ids) != len(set(action_ids)):
        errors.append("duplicate action ID")
    known_ids = set(user_ids + overlay_ids)
    if not set(observation["entityIds"]).issubset(known_ids):
        errors.append("unknown observation entity")
    if not all(item["targetEntityId"] in observation["entityIds"] for item in response["actions"]):
        errors.append("unknown action target")
    return errors


def main():
    canvas = load("examples/canvas-snapshot.json")
    observation = load("examples/observation.json")
    response = load("examples/tutor-response.json")
    for schema, value in (("canvas", canvas), ("observation", observation), ("tutor-response", response)):
        validate(schema, value)
    assert binding_errors(canvas, observation, response) == []

    # No model-supplied canvas coordinates or destructive user-ink commands.
    for key, value in (("worldX", 100), ("type", "delete_user_ink")):
        bad = copy.deepcopy(response)
        bad["actions"][0][key] = value
        try:
            validate("tutor-response", bad)
        except Exception as exc:
            from jsonschema import ValidationError
            if not isinstance(exc, ValidationError):
                raise
        else:
            raise AssertionError(f"unexpectedly accepted {key}")

    stale = copy.deepcopy(response)
    stale["observedRevision"] -= 1
    assert "stale revision" in binding_errors(canvas, observation, stale)
    unknown = copy.deepcopy(response)
    unknown["actions"][0]["targetEntityId"] = "bfcdbf69-3b04-483d-9d64-24f848b5fe17"
    assert "unknown action target" in binding_errors(canvas, observation, unknown)
    print("Contracts: examples valid; unsafe and stale responses rejected")


if __name__ == "__main__":
    main()
