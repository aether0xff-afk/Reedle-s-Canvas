"""Validate example contracts and the most important rejected tutor commands.

Run with: python tools/validate_contracts.py (requires jsonschema).
"""

import copy
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError


ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


def validate(schema_name, value):
    schema = load(f"contracts/{schema_name}-v1.schema.json")
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(value)


def expect_invalid_response(response):
    try:
        validate("tutor-response", response)
    except ValidationError:
        return
    raise AssertionError(f"unexpectedly accepted response: {response!r}")


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
        expect_invalid_response(bad)

    validate("tutor-response", {**response, "decision": "observe_only", "actions": []})
    expect_invalid_response({**response, "decision": "observe_only"})
    expect_invalid_response({**response, "actions": []})
    drawing = {**response["actions"][0], "type": "draw", "content": "circle"}
    validate("tutor-response", {**response, "actions": [drawing]})
    expect_invalid_response({**response, "actions": [{**drawing, "content": "plot(x); window.open(url)"}]})

    stale = copy.deepcopy(response)
    stale["observedRevision"] -= 1
    assert "stale revision" in binding_errors(canvas, observation, stale)
    unknown = copy.deepcopy(response)
    unknown["actions"][0]["targetEntityId"] = "bfcdbf69-3b04-483d-9d64-24f848b5fe17"
    assert "unknown action target" in binding_errors(canvas, observation, unknown)
    wrong_note = {**response, "noteId": unknown["actions"][0]["targetEntityId"]}
    assert "note mismatch" in binding_errors(canvas, observation, wrong_note)
    wrong_request = {**response, "requestId": canvas["aiOverlay"][0]["provenance"]["requestId"]}
    assert "request mismatch" in binding_errors(canvas, observation, wrong_request)
    duplicate = {**response, "actions": response["actions"] * 2}
    assert "duplicate action ID" in binding_errors(canvas, observation, duplicate)
    print("Contracts passed: snapshots, observations, tutor actions and response binding")


if __name__ == "__main__":
    main()
