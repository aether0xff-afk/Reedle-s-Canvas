from argparse import ArgumentParser, ArgumentTypeError
import json
from math import isfinite
from pathlib import Path

from server.reedle_server.contract import parse_json

from .dataset import load_manifest, synthetic_cases, write_manifest
from .runner import Limits, Replay, audit_dataset, build_report, live_records


def _positive(raw: str) -> float:
    value = float(raw)
    if not isfinite(value) or value <= 0:
        raise ArgumentTypeError("must be a positive finite number")
    return value


def _probability(raw: str) -> float:
    value = float(raw)
    if not 0 <= value <= 1:
        raise ArgumentTypeError("must be between 0 and 1")
    return value


def _options(parser: ArgumentParser) -> None:
    defaults = Limits()
    parser.add_argument("--manifest", type=Path, help="external PNG manifest, defaults to the synthetic corpus")
    parser.add_argument("--report", type=Path, help="write the JSON report to this path")
    parser.add_argument("--max-fpr", type=_probability, default=defaults.max_fpr)
    parser.add_argument("--max-fnr", type=_probability, default=defaults.max_fnr)
    parser.add_argument("--max-p50-ms", type=_positive, default=defaults.max_p50_ms)
    parser.add_argument("--max-p95-ms", type=_positive, default=defaults.max_p95_ms)


def _write_json(path: Path | None, value: dict) -> None:
    output = json.dumps(value, indent=2, ensure_ascii=True)
    if path is None:
        print(output)
    else:
        path.write_text(output + "\n", encoding="utf-8")


def main() -> int:
    parser = ArgumentParser(description="Evaluate Reedle tutor handwriting crops")
    commands = parser.add_subparsers(dest="command", required=True)
    render = commands.add_parser("render", help="write the synthetic PNG corpus and its manifest")
    render.add_argument("directory", type=Path)
    audit = commands.add_parser("audit", help="validate local images, labels and gateway request sizes without sending data")
    audit.add_argument("--manifest", type=Path, required=True)
    audit.add_argument("--report", type=Path)
    replay = commands.add_parser("replay", help="score a saved replay offline")
    _options(replay)
    replay.add_argument("input", type=Path)
    replay_scope = replay.add_mutually_exclusive_group()
    replay_scope.add_argument("--fixture-scope", action="store_true", help="score only the IDs in a fixture replay")
    replay_scope.add_argument("--case", action="append", help="restrict to case IDs, repeat to select several")
    live = commands.add_parser("live", help="send crops to an explicitly selected HTTPS gateway")
    _options(live)
    live.add_argument("--endpoint", required=True)
    live.add_argument("--case", action="append", help="restrict to case IDs, repeat to select several")
    live.add_argument("--stream", action="store_true", help="measure the iPad gateway event stream")
    live.add_argument("--record", type=Path, help="write responses in replay format")
    args = parser.parse_args()
    try:
        if args.command == "render":
            print(write_manifest(args.directory, synthetic_cases()))
            return 0
        cases = load_manifest(args.manifest) if args.manifest else synthetic_cases()
        if args.command == "audit":
            _write_json(args.report, audit_dataset(cases))
            return 0
        dataset_size = len(cases)
        if args.case:
            selected = set(args.case)
            if len(selected) != len(args.case) or not selected.issubset(case.id for case in cases):
                raise ValueError("--case must name unique IDs from the dataset")
            cases = tuple(case for case in cases if case.id in selected)
        limits = Limits(args.max_fpr, args.max_fnr, args.max_p50_ms, args.max_p95_ms)
        if args.command == "replay":
            # Parse once to reject duplicate keys, then let Pydantic apply the JSON field types.
            capture = Replay.model_validate_json(json.dumps(parse_json(args.input.read_bytes())))
            if args.fixture_scope:
                if capture.source != "fixture":
                    raise ValueError("--fixture-scope is only available for fixture replays")
                ids = {record.case_id for record in capture.records}
                cases = tuple(case for case in cases if case.id in ids)
        else:
            if args.report and args.record and args.report.resolve() == args.record.resolve():
                raise ValueError("--report and --record require different files")
            capture = live_records(cases, args.endpoint, stream=args.stream)
            if args.record:
                _write_json(args.record, capture.model_dump(mode="json", exclude_none=True))
        report = build_report(cases, capture, limits)
        _write_json(args.report, {"dataset_size": dataset_size, **report})
        return 0 if report["scope_complete"] else 1
    except (OSError, ValueError, RecursionError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
