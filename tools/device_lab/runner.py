"""Local laptop collector. Never reports unexecuted hardware tests as passed."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile

LAB_BUNDLE = "dev.aether.reedlescanvas.devicelab"
PLAYGROUNDS_BUNDLE = "com.apple.Playgrounds"
MAX_REPORT_BYTES = 2_000_000


def select_device(devices: list, requested: str | None = None) -> str:
    ids = list(dict.fromkeys(d.get("UniqueDeviceID", d.get("Identifier"))
                            for d in devices if isinstance(d, dict)))
    ids = [i for i in ids if isinstance(i, str) and i]
    if requested:
        if requested not in ids:
            raise ValueError("Requested device not found; unlock it and trust this laptop.")
        return requested
    if len(ids) > 1:
        raise ValueError("There are multiple devices; rerun with -Udid <device-id>.")
    if not ids:
        raise ValueError("No paired USB iPad found. Install/open Apple Devices, unlock iPad and tap Trust.")
    return ids[0]


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def grade_report(r: dict) -> dict:
    frames, verify = r.get("frames", {}), r.get("verification", {})
    workload = r.get("workload_frames", {})
    physical = r.get("environment", {}).get("is_simulator") is False
    provenance = bool(re.fullmatch(r"[0-9a-f]{40}", str(r.get("source_commit", ""))))
    valid_frames = (finite_number(frames.get("sample_count")) and frames["sample_count"] > 0
                    and finite_number(frames.get("p95_ms")) and frames["p95_ms"] > 0)
    duration, planned = r.get("duration_seconds"), r.get("planned_seconds")
    actual_work = (finite_number(planned) and planned >= 90 and finite_number(duration) and duration >= planned
                   and finite_number(r.get("applied_navigation_requests")) and r["applied_navigation_requests"] > 0
                   and finite_number(workload.get("sample_count")) and workload["sample_count"] > 0
                   and finite_number(workload.get("p95_ms")) and workload["p95_ms"] > 0)
    measured = (physical and provenance and r.get("completed") is True and valid_frames and actual_work
                and r.get("fixture_strokes") == 10000 and verify.get("stroke_records_equal") is True
                and finite_number(verify.get("reopened_stroke_count"))
                and verify["reopened_stroke_count"] >= 10000
                and finite_number(r.get("peak_footprint_bytes")) and r["peak_footprint_bytes"] > 0)
    b = r.get("battery", {})
    start, end = b.get("start_level"), b.get("end_level")
    samples = r.get("samples", [])
    valid_battery_samples = (isinstance(samples, list) and len(samples) >= 2
                             and all(isinstance(s, dict) and finite_number(s.get("battery_level"))
                                     and 0 <= s["battery_level"] <= 1 and s.get("battery_unplugged") is True
                                     for s in samples)
                             and samples[0]["battery_level"] == start and samples[-1]["battery_level"] == end)
    battery_ok = (physical and provenance and r.get("completed") is True and finite_number(duration) and duration >= 600
                  and b.get("drop_estimate_eligible") is True and valid_battery_samples
                  and b.get("all_samples_unplugged") is True
                  and all(finite_number(n) and 0 <= n <= 1 for n in (start, end)) and end <= start)
    remaining = ["Physical Pencil response/operator or high-speed-video evidence",
                 "Actual iPadOS rotation/window-management and background/relaunch evidence",
                 "Review raw results for crashes, data loss and blocking bugs"]
    if not measured:
        remaining.append("Completed physical 10,000-stroke workload with valid source, frame and memory records")
    if not battery_ok:
        remaining.append("At least 600 seconds with all sampled battery states unplugged and valid levels")
    return {"physical_workload_recorded": bool(measured), "source_provenance_present": provenance,
            "frame_scope": "app display-link callback cadence, not contact-to-photon latency or independent display FPS",
            "battery_drop_percentage_points": round((start - end) * 100, 6) if battery_ok else None,
            "battery_scope": "whole-device coarse battery level; not isolated app power consumption",
            "aet49_complete": False, "remaining": remaining}


def read_report(path: Path) -> dict:
    if path.stat().st_size > MAX_REPORT_BYTES:
        raise ValueError("Lab report exceeds the 2 MB limit.")
    r = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(r, dict) or r.get("schema_version") != 1:
        raise ValueError("Unsupported lab report schema.")
    if any(not isinstance(r.get(k), dict) for k in ("environment", "frames", "workload_frames", "verification", "battery")):
        raise ValueError("Malformed nested lab report fields.")
    return r


def stream_summary(kind: str, text: str) -> dict:
    records, bad = [], 0
    for line in text.splitlines():
        if not line.strip(): continue
        try:
            value = json.loads(line)
            if not isinstance(value, dict): raise ValueError("not an object")
            records.append(value)
        except (ValueError, TypeError): bad += 1
    summary = {"samples": len(records), "invalid_lines": bad}
    if kind == "fps":
        fps = [r["fps"] for r in records if finite_number(r.get("fps")) and 0 <= r["fps"] <= 240]
        summary.update(valid_fps_samples=len(fps), fps_min=min(fps) if fps else None,
                       fps_mean=sum(fps) / len(fps) if fps else None,
                       scope="device-wide Core Animation FPS; foreground app must be checked separately")
    return summary


def video_latency(contact: int, ink: int, fps: float) -> dict:
    if (not finite_number(fps) or fps <= 0 or fps > 10000 or contact < 0 or ink < contact):
        raise ValueError("Use positive original capture FPS and ordered nonnegative frame indices.")
    return {"contact_frame": contact, "first_ink_frame": ink, "original_capture_fps": fps,
            "latency_ms": (ink - contact) * 1000 / fps, "one_frame_resolution_ms": 1000 / fps,
            "scope": "operator-selected high-speed video frames; not device screen recording"}


def write_json(path: Path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def archive_results(folder: Path) -> Path:
    folder = folder.resolve()
    files = []
    for p in sorted(folder.rglob("*")):
        if p.is_symlink(): raise ValueError("Result folders must not contain symlinks.")
        if p.is_file() and p.name != "manifest.json":
            files.append({"path": p.relative_to(folder).as_posix(), "bytes": p.stat().st_size,
                          "sha256": hashlib.sha256(p.read_bytes()).hexdigest()})
    write_json(folder / "manifest.json", {"schema_version": 1, "files": files})
    target = folder.with_suffix(".zip")
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for entry in files:
            z.write(folder / entry["path"], entry["path"])
        z.write(folder / "manifest.json", "manifest.json")
    return target


def command(args: list[str], timeout=30) -> dict:
    env = dict(os.environ, PYTHONUNBUFFERED="1", NO_COLOR="1")
    for key in ("BAZE_API_KEY", "OPENAI_API_KEY", "REEDLE_CLIENT_TOKEN"):
        env.pop(key, None)
    try:
        r = subprocess.run([sys.executable, "-m", "pymobiledevice3", *args],
                           capture_output=True, text=True, encoding="utf-8", errors="replace",
                           timeout=timeout, env=env)
        return {"returncode": r.returncode, "stdout": r.stdout, "stderr": r.stderr, "timeout": False}
    except subprocess.TimeoutExpired as e:
        def decoded(v): return v.decode("utf-8", "replace") if isinstance(v, bytes) else v or ""
        return {"returncode": None, "stdout": decoded(e.stdout), "stderr": decoded(e.stderr), "timeout": True}


def stream(args: list[str], seconds: int, prefix: Path) -> dict:
    # Files avoid pipe deadlocks and unbounded in-memory output. Each child is always reaped.
    env = dict(os.environ, PYTHONUNBUFFERED="1", NO_COLOR="1")
    for key in ("BAZE_API_KEY", "OPENAI_API_KEY", "REEDLE_CLIENT_TOKEN"): env.pop(key, None)
    with prefix.with_suffix(".jsonl").open("wb") as out, prefix.with_suffix(".stderr.txt").open("wb") as err:
        process = subprocess.Popen([sys.executable, "-m", "pymobiledevice3", *args],
                                   stdout=out, stderr=err, env=env)
        bounded_stop = False
        try:
            process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            bounded_stop = True
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
    return {"exit_code": process.returncode, "stopped_at_time_limit": bounded_stop,
            **stream_summary(prefix.name, prefix.with_suffix(".jsonl").read_text(encoding="utf-8"))}


def collect(args, folder: Path, udid: str) -> dict:
    pid_result = command(["developer", "dvt", "process-id-for-bundle-id", "--udid", udid, LAB_BUNDLE])
    write_json(folder / "lab-process.json", pid_result)
    if pid_result["returncode"] != 0 or not re.fullmatch(r"\s*[1-9][0-9]*\s*", pid_result["stdout"]):
        return {"hardware_telemetry": "unavailable", "reason": "Open and run the Device Lab playground; DVT also requires Developer Mode/DDI support.", "process_query": pid_result}
    pid = pid_result["stdout"].strip()
    tasks = {"fps": ["developer", "dvt", "fps", "--udid", udid],
             "process": ["developer", "dvt", "sysmon", "process", "monitor", "process", "--udid", udid,
                         "--filter", f"pid={pid}", "--duration", str(args.seconds * 1000)]}
    print(f"Collecting {args.seconds}s of device FPS and lab-process memory. Keep the lab in front.", flush=True)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {k: pool.submit(stream, v, args.seconds, folder / k) for k, v in tasks.items()}
        stats = {k: f.result() for k, f in futures.items()}
    pull = command(["apps", "pull", "--documents", "--udid", udid, LAB_BUNDLE,
                    "/ReedleDeviceLab/Results", str(folder / "device-reports")])
    write_json(folder / "report-pull.json", pull)
    valid_streams = all(s["samples"] > 0 and s["invalid_lines"] == 0
                        and (s["exit_code"] == 0 or s["stopped_at_time_limit"]) for s in stats.values())
    return {"hardware_telemetry": "recorded" if valid_streams else "partial_or_missing",
            "streams": stats, "report_pull_succeeded": pull["returncode"] == 0}


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=["prepare", "collect", "import", "latency", "validate"])
    p.add_argument("--udid"); p.add_argument("--seconds", type=int, default=90)
    p.add_argument("--output", type=Path, default=Path(__file__).parent / "results")
    p.add_argument("--report", type=Path)
    p.add_argument("--contact-frame", type=int); p.add_argument("--ink-frame", type=int); p.add_argument("--fps", type=float)
    args = p.parse_args(argv)
    if not 10 <= args.seconds <= 3600: p.error("seconds must be 10..3600")
    folder = args.output / datetime.now(timezone.utc).strftime("run-%Y%m%dT%H%M%S-%fZ")
    folder.mkdir(parents=True, exist_ok=False)
    summary = {"mode": args.mode, "created_utc": datetime.now(timezone.utc).isoformat(), "aet49_complete": False}
    exit_code = 0
    try:
        if args.mode == "validate":
            summary["status"] = "runner ready; no hardware test executed"
        elif args.mode == "import":
            if args.report is None: raise ValueError("Specify --report with the exported Device Lab JSON.")
            r = read_report(args.report); write_json(folder / "device-lab.json", r)
            summary.update(status="imported", grading=grade_report(r))
        elif args.mode == "latency":
            if None in (args.contact_frame, args.ink_frame, args.fps): raise ValueError("Specify all video frame arguments.")
            summary.update(status="video annotation", latency=video_latency(args.contact_frame, args.ink_frame, args.fps))
        else:
            devices = command(["usbmux", "list", "--usb"])
            if devices["returncode"] != 0:
                write_json(folder / "discovery-error.json", devices)
                raise ValueError("USB discovery failed. Install/open Apple Devices and approve Trust on unlocked iPad.")
            udid = select_device(json.loads(devices["stdout"]), args.udid)
            info = command(["lockdown", "info", "--udid", udid])
            if info["returncode"] != 0:
                write_json(folder / "pairing-error.json", info)
                raise ValueError("iPad connection/pairing failed; unlock and approve Trust, then rerun.")
            raw = json.loads(info["stdout"])
            summary["device"] = {k: raw.get(k) for k in ("ProductType", "ProductVersion", "BuildVersion", "CPUArchitecture")}
            summary["device"]["identifier_sha256_prefix"] = hashlib.sha256(udid.encode()).hexdigest()[:12]
            if args.mode == "prepare":
                source = Path(__file__).parent / "ReedlesCanvas-DeviceLab.swiftpm.zip"
                if not source.is_file(): raise ValueError("Device Lab source ZIP missing; use the complete laptop kit.")
                push = command(["apps", "push", "--documents", "--udid", udid, PLAYGROUNDS_BUNDLE,
                                str(source), "/ReedleDeviceLab-Source.zip"], timeout=60)
                write_json(folder / "source-transfer.json", push)
                summary.update(status="device ready", source_transfer_succeeded=push["returncode"] == 0,
                               next_step="On iPad open the ZIP in Swift Playgrounds Documents (or copy with Files/iCloud), unzip and run. See START-HERE.md.")
            else:
                summary.update(collect(args, folder, udid))
                for path in sorted((folder / "device-reports").rglob("report.json")):
                    summary["grading"] = grade_report(read_report(path))
    except (ValueError, OSError, json.JSONDecodeError) as e:
        summary.update(status="needs_setup_or_evidence", error=str(e)); exit_code = 2
    finally:
        write_json(folder / "summary.json", summary)
        archive = archive_results(folder)
        print(json.dumps({"result_zip": str(archive.resolve()), "summary": summary}, ensure_ascii=True, indent=2), flush=True)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
