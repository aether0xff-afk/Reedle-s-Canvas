"""Offline, bounded crash triage. Output stays local and needs review before sharing."""
from __future__ import annotations

import json
from pathlib import Path
import re

MAX_CRASH_BYTES = 16_000_000
RELATED_PROCESS = re.compile(r"Reedle|DeviceLab|AppModule|^(?:Swift[ -]?)?Playgrounds?(?:$|[ ._-])", re.I)


def _fields(value, names):
    return {key: value[key] for key in names if key in value} if isinstance(value, dict) else {}


def _stack(frames, images):
    frames = frames if isinstance(frames, list) else []
    result = []
    for frame in frames[:64]:
        row = _fields(frame, ("symbol", "symbolLocation", "imageIndex", "imageOffset"))
        index = row.get("imageIndex")
        if isinstance(index, int) and not isinstance(index, bool) and 0 <= index < len(images):
            row["image"] = _fields(images[index], ("name", "uuid", "arch"))
        if row: result.append(row)
    return result


def analyze_crash(path: Path) -> dict:
    if path.stat().st_size > MAX_CRASH_BYTES:
        raise ValueError("Crash report exceeds the 16 MB analysis limit; original retained.")
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    result = {"file": path.name, "root_cause_confirmed": False,
              "scope": "local triage only; review/redact before publication; absent stacks are inconclusive"}
    if not text.lstrip().startswith("{"):
        fields = {}
        for label in ("Process", "Identifier", "OS Version", "Exception Type", "Exception Codes", "Termination Reason"):
            match = re.search(r"^" + re.escape(label) + r":\s*(.+)$", text, re.M)
            if match: fields[label] = match.group(1)
        thread = re.search(r"^(?:Crashed Thread|Triggered by Thread):\s*(\d+)", text, re.M)
        if not thread:
            thread = re.search(r"^Thread (\d+) Crashed:", text, re.M)
        stack = []
        if thread:
            block = re.search(r"^Thread " + thread.group(1) + r" Crashed:[^\n]*\n((?:[^\n]+\n?)+)", text, re.M)
            if block: stack = [line for line in block.group(1).splitlines() if re.match(r"^\d+\s", line)][:64]
        return {**result, "format": "legacy", "parse_status": "parsed" if fields else "unsupported",
                "fields": fields, "faulting_thread": int(thread.group(1)) if thread else None,
                "faulting_stack": stack, "stack_available": bool(stack)}

    # Apple .ips files can have a metadata JSON object followed by a second JSON body.
    decoder = json.JSONDecoder()
    objects, position = [], 0
    while position < len(text):
        while position < len(text) and text[position].isspace(): position += 1
        if position == len(text): break
        value, position = decoder.raw_decode(text, position)
        if isinstance(value, dict): objects.append(value)
        if len(objects) > 2: raise ValueError("Unexpected extra crash JSON objects; original retained.")
    header = objects[0] if objects else {}
    body = objects[-1] if objects else {}
    result.update(format="ips", bug_type=header.get("bug_type", body.get("bug_type")),
                  process=body.get("procName", header.get("app_name")),
                  bundle=_fields(body.get("bundleInfo"), ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")),
                  os=_fields(body.get("osVersion"), ("train", "build", "releaseType")),
                  os_version=header.get("os_version"), timestamp=body.get("captureTime", header.get("timestamp")),
                  product=body.get("product", body.get("modelCode")))
    if str(result["bug_type"]) == "298" or ("processes" in body and "memoryStatus" in body):
        processes = body.get("processes", [])
        processes = processes if isinstance(processes, list) else []
        memory_status = body.get("memoryStatus", {})
        memory_status = memory_status if isinstance(memory_status, dict) else {}
        related = [_fields(p, ("name", "reason", "states", "rpages", "lifetimeMax", "killed"))
                   for p in processes if isinstance(p, dict) and RELATED_PROCESS.search(str(p.get("name", "")))]
        return {**result, "parse_status": "parsed", "kind": "jetsam", "related_processes": related,
                "page_size_bytes": body.get("pageSize", memory_status.get("pageSize")), "stack_available": False,
                "termination_evidence": any(p.get("reason") or p.get("killed") is True for p in related),
                "interpretation": "A Jetsam report or largest process alone does not prove this app was killed."}
    threads = body.get("threads", [])
    threads = threads if isinstance(threads, list) else []
    fault = body.get("faultingThread")
    if not isinstance(fault, int) or isinstance(fault, bool) or not 0 <= fault < len(threads):
        fault = next((i for i, t in enumerate(threads) if isinstance(t, dict) and t.get("triggered") is True), None)
    images = body.get("usedImages", [])
    images = images if isinstance(images, list) else []
    thread = threads[fault] if fault is not None and isinstance(threads[fault], dict) else {}
    stack = _stack(thread.get("frames", []), images)
    exception_stack = _stack(body.get("lastExceptionBacktrace", []), images)
    return {**result, "kind": "crash", "parse_status": "parsed" if body.get("exception") or body.get("termination") or threads else "unsupported",
            "exception": _fields(body.get("exception"), ("type", "signal", "subtype", "codes", "message")),
            "termination": _fields(body.get("termination"), ("namespace", "code", "indicator", "byProc")),
            "faulting_thread": fault, "faulting_stack": stack, "stack_available": bool(stack),
            "last_exception_stack": exception_stack,
            "symbolicated_frames": sum(bool(f.get("symbol")) for f in stack)}
