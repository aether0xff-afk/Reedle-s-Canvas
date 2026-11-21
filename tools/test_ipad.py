"""Run iPad unit and UI tests through Xcode and keep the result bundle."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def ipad_identifier(devices):
    candidates = []
    for runtime, inventory in devices.items():
        platform, *version = runtime.rsplit(".", 1)[-1].split("-")
        if platform != "iOS" or not version or not all(part.isdigit() for part in version):
            continue
        release = tuple(map(int, version))
        if release[0] < 17:
            continue
        for device in inventory:
            if device["deviceTypeIdentifier"].rsplit(".", 1)[-1].startswith("iPad"):
                candidates.append((device["state"] == "Booted", release, device["name"], device["udid"]))
    if not candidates:
        raise SystemExit("Install an iOS 17+ simulator runtime and create an iPad simulator in Xcode.")
    _, _, name, udid = max(candidates)
    print(f"iPad simulator: {name} ({udid})", flush=True)
    return udid


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    destination = parser.add_mutually_exclusive_group()
    destination.add_argument("--device", help="UDID of a specific iPad simulator")
    destination.add_argument("--physical-device", help="UDID of an attached, development-enabled iPad")
    parser.add_argument("--team-id", help="Apple signing team for a physical device run")
    args = parser.parse_args(argv)
    if args.physical_device:
        if not args.team_id or not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
            parser.error("--physical-device requires a 10-character --team-id")
    elif args.team_id:
        parser.error("--team-id is for --physical-device")
    udid = args.device or args.physical_device
    if udid and not re.fullmatch(r"[0-9A-Fa-f-]{8,64}", udid):
        parser.error("Enter a device or simulator UDID")
    return args


def xcode_test_args(args, udid, bundle):
    physical = bool(args.physical_device)
    variant = "iOS" if physical else "iOS Simulator"
    command = [
        "xcodebuild", "-project", "ReedlesCanvas.xcodeproj", "-scheme", "ReedlesCanvas", "-configuration", "Debug",
        "-sdk", "iphoneos" if physical else "iphonesimulator",
        "-destination", f"platform={variant},id={udid}",
        "-derivedDataPath", "DerivedData", "-parallel-testing-enabled", "NO", "-resultBundlePath", str(bundle),
    ]
    if physical:
        command += [f"DEVELOPMENT_TEAM={args.team_id}", "OTHER_SWIFT_FLAGS=$(inherited) -DREEDLE_UI_TEST_SUPPORT"]
    return command + ["test"]


def extract_result_reports(bundle):
    if not bundle.is_dir():
        return
    for item in ("summary", "metrics"):
        result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", item, "--path", str(bundle)],
                                capture_output=True, text=True, encoding="utf-8", errors="replace")
        if result.returncode == 0:
            (bundle.parent / f"{item}.json").write_text(result.stdout, encoding="utf-8")


def main():
    args = parse_arguments()
    if sys.platform != "darwin":
        print("iPad XCTest requires Xcode on macOS. Use tools/test_core.py for WSL coverage.", file=sys.stderr)
        return 2

    root = Path(__file__).resolve().parents[1]
    udid = args.physical_device or args.device or ipad_identifier(json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"]
    ))["devices"])
    subprocess.run(["xcodegen", "generate"], cwd=root, check=True)
    results = root / ".build" / "ipad-tests"
    results.mkdir(parents=True, exist_ok=True)
    bundle = Path(tempfile.mkdtemp(prefix="run-", dir=results)) / "ReedlesCanvas.xcresult"
    started = datetime.now(timezone.utc).isoformat()
    variant = "physical iPad" if args.physical_device else "iPad Simulator"
    print(f"Test results: {bundle}", flush=True)
    with (bundle.parent / "xcodebuild.log").open("w", encoding="utf-8") as log:
        with subprocess.Popen(xcode_test_args(args, udid, bundle), cwd=root, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace") as build:
            for line in build.stdout:
                log.write(line)
                print(line, end="", flush=True)
            status = build.wait()
    (bundle.parent / "run.json").write_text(json.dumps({
        "started_at": started, "destination": variant, "xcodebuild_exit_code": status,
        "result_bundle": bundle.name if bundle.exists() else None,
    }, indent=2) + "\n", encoding="utf-8")
    extract_result_reports(bundle)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
