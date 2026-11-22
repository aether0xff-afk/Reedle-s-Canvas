import importlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from datetime import date
from unittest.mock import patch
import zipfile

try:
    lab = importlib.import_module("tools.device_lab.runner")
except ModuleNotFoundError:
    lab = None


class DeviceLabRunnerTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(lab, "The laptop device collector must exist")

    def report(self):
        return {"schema_version": 1, "source_commit": "a" * 40,
                "environment": {"is_simulator": False}, "completed": True,
                "duration_seconds": 600, "planned_seconds": 600, "fixture_strokes": 10000,
                "applied_navigation_requests": 200,
                "verification": {"stroke_records_equal": True, "reopened_stroke_count": 10000},
                "frames": {"sample_count": 900, "p95_ms": 17},
                "workload_frames": {"sample_count": 800, "p95_ms": 17},
                "peak_footprint_bytes": 120000000,
                "battery": {"start_level": .8, "end_level": .78,
                            "all_samples_unplugged": True, "drop_estimate_eligible": True},
                "samples": [{"elapsed_seconds": 0, "battery_level": .8, "battery_unplugged": True},
                            {"elapsed_seconds": 600, "battery_level": .78, "battery_unplugged": True}]}

    def test_requires_choice_for_multiple_devices(self):
        with self.assertRaisesRegex(ValueError, "multiple"):
            lab.select_device([{"UniqueDeviceID": "one"}, {"UniqueDeviceID": "two"}])
        self.assertEqual(lab.select_device([{"UniqueDeviceID": "one"}, {"UniqueDeviceID": "two"}], "two"), "two")

    def test_missing_requested_device_does_not_fall_back(self):
        with self.assertRaisesRegex(ValueError, "not found"):
            lab.select_device([{"UniqueDeviceID": "one"}], "other")

    def test_simulator_report_cannot_count_as_physical(self):
        r = self.report(); r["environment"]["is_simulator"] = True
        self.assertFalse(lab.grade_report(r)["physical_workload_recorded"])

    def test_charging_battery_and_short_runs_are_inconclusive(self):
        r = self.report(); r["battery"]["all_samples_unplugged"] = False
        self.assertIsNone(lab.grade_report(r)["battery_drop_percentage_points"])
        r["battery"]["all_samples_unplugged"] = True; r["duration_seconds"] = 90
        self.assertIsNone(lab.grade_report(r)["battery_drop_percentage_points"])

    def test_recorded_battery_is_whole_device_and_not_app_power(self):
        g = lab.grade_report(self.report())
        self.assertAlmostEqual(g["battery_drop_percentage_points"], 2)
        self.assertIn("whole-device", g["battery_scope"])
        self.assertFalse(g["aet49_complete"])
        self.assertIn("Pencil", " ".join(g["remaining"]))

    def test_unknown_intermediate_battery_sample_cannot_make_a_drop_estimate(self):
        r = self.report()
        r["samples"].insert(1, {"elapsed_seconds": 300, "battery_level": -1, "battery_unplugged": True})
        r["battery"]["drop_estimate_eligible"] = False
        self.assertIsNone(lab.grade_report(r)["battery_drop_percentage_points"])

    def test_no_actual_navigation_or_workload_frames_is_not_a_physical_workload(self):
        for key, value in [("workload_frames", {"sample_count": 0}),
                           ("applied_navigation_requests", 0), ("duration_seconds", 0)]:
            r = self.report(); r[key] = value
            self.assertFalse(lab.grade_report(r)["physical_workload_recorded"])

    def test_malformed_nested_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "report.json"
            p.write_text('{"schema_version":1,"environment":[],"frames":null}')
            with self.assertRaises(ValueError): lab.read_report(p)

    def test_missing_frames_or_failed_restore_never_pass(self):
        for key, value in [("frames", {"sample_count": 0}),
                           ("verification", {"stroke_records_equal": False})]:
            r = self.report(); r[key] = value
            self.assertFalse(lab.grade_report(r)["physical_workload_recorded"])

    def test_import_is_bounded_and_validates_schema(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "report.json"; p.write_text(json.dumps(self.report()))
            self.assertEqual(lab.read_report(p)["source_commit"], "a" * 40)
            p.write_text('{"schema_version":999}')
            with self.assertRaises(ValueError): lab.read_report(p)

    def test_empty_and_invalid_streams_are_reported_as_missing(self):
        self.assertEqual(lab.stream_summary("fps", "")["samples"], 0)
        self.assertEqual(lab.stream_summary("fps", 'bad\n{"fps":60}\n')["invalid_lines"], 1)
        self.assertEqual(lab.stream_summary("fps", '{"fps":60}\n')["fps_min"], 60)

    def test_zip_lists_only_local_results_and_matches_hashes(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "run"; folder.mkdir()
            (folder / "summary.json").write_text('{}')
            target = lab.archive_results(folder)
            with zipfile.ZipFile(target) as z:
                self.assertIsNone(z.testzip())
                self.assertEqual(set(z.namelist()), {"summary.json", "manifest.json"})
                self.assertEqual(json.loads(z.read("manifest.json"))["files"][0]["path"], "summary.json")

    def test_latency_requires_ordered_video_frames(self):
        self.assertAlmostEqual(lab.video_latency(100, 103, 240)["latency_ms"], 12.5)
        with self.assertRaises(ValueError): lab.video_latency(103, 100, 240)
        with self.assertRaises(ValueError): lab.video_latency(100, 103, 0)

    def test_crash_selection_is_recent_scoped_and_rejects_unsafe_paths(self):
        self.assertTrue(hasattr(lab, "select_crash_reports"), "Existing crash reports need a safe collector")
        listing = ["AppModule-2026-11-22-160000.ips", "Playgrounds-2026-11-21-180000.ips",
                   "Safari-2026-11-22-160001.ips", "AppModule-2026-10-01-120000.ips",
                   "../AppModule-2026-11-22.ips", "C:/AppModule-2026-11-22.ips",
                   "JetsamEvent-2026-11-22-160000.ips"]
        chosen = lab.select_crash_reports(listing, date(2026, 11, 22))
        self.assertEqual(set(chosen), {listing[0], listing[1], listing[-1]})

    def test_diagnostics_collects_existing_reports_without_launching_or_deleting(self):
        self.assertTrue(hasattr(lab, "diagnose"), "Crash diagnostics must not require rerunning the workload")
        calls = []
        def fake(args, timeout=30):
            calls.append(args)
            stdout = ""
            if args[:2] == ["crash", "ls"]:
                stdout = "AppModule-2026-11-22-160000.ips\nSafari-2026-11-22-160000.ips\n"
            if args[:2] == ["apps", "list"]:
                stdout = json.dumps({"com.apple.Playgrounds": {"CFBundleName": "Playgrounds"},
                                     "private.personal.app": {"CFBundleName": "Private"}})
            if args[:2] == ["crash", "pull"]:
                folder = Path(args[args.index("--udid") + 2]); folder.mkdir(exist_ok=True)
                (folder / "AppModule-2026-11-22-160000.ips").write_text('{}')
            return {"returncode": 0, "stdout": stdout, "stderr": "", "timeout": False}
        with tempfile.TemporaryDirectory() as d, patch.object(lab, "command", side_effect=fake):
            result = lab.diagnose(Path(d), "local-test-device", today=date(2026, 11, 22))
            self.assertEqual(result["crash_reports_copied"], 1)
            self.assertTrue(result["no_workload_launched"])
            self.assertNotIn("private.personal.app", (Path(d) / "app-identities.json").read_text())
        self.assertTrue(all("--erase" not in c and "clear" not in c and "launch" not in c for c in calls))

    def test_failed_source_transfer_is_not_reported_as_ready_to_run(self):
        self.assertTrue(hasattr(lab, "source_transfer_status"))
        result = lab.source_transfer_status({"returncode": 1})
        self.assertFalse(result["source_transfer_succeeded"])
        self.assertEqual(result["status"], "device_connected_source_not_transferred")

    def test_denied_host_socket_is_not_reported_as_missing_trust(self):
        with patch.object(lab.sys, "platform", "win32"), patch.object(lab.socket, "create_connection", side_effect=OSError(10013, "denied")):
            probe = lab.usb_transport_probe()
        self.assertEqual(probe["status"], "access_denied")
        with tempfile.TemporaryDirectory() as d, patch.object(lab, "usb_transport_probe", return_value=probe), \
                patch.object(lab, "command") as command, patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(lab.main(["diagnose", "--output", d]), 2)
            command.assert_not_called()
            summary = json.loads(next(Path(d).glob("*/summary.json")).read_text())
            self.assertEqual(summary["status"], "blocked_host_transport")
            self.assertEqual(summary["device_state"], "unknown")
            self.assertFalse(summary["aet49_complete"])

    def test_report_pull_survives_unavailable_dvt_and_uses_discovered_bundle(self):
        calls = []
        bundle = "example.actual.preview"
        def fake(args, timeout=30):
            calls.append(args)
            text = json.dumps({bundle: {"CFBundleDisplayName": "ReedleDeviceLab"},
                               "private.app": {"CFBundleDisplayName": "Private"}}) if args[:2] == ["apps", "list"] else "0\n"
            return {"returncode": 0, "stdout": text, "stderr": "", "timeout": False}
        with tempfile.TemporaryDirectory() as d, patch.object(lab, "command", side_effect=fake):
            result = lab.collect(SimpleNamespace(seconds=90, bundle_id=None), Path(d), "test-device")
            self.assertTrue(result["report_pull_succeeded"])
            self.assertEqual(result["hardware_telemetry"], "unavailable")
            self.assertTrue(result["app_selection"]["confirmed_installed"])
            self.assertNotIn("private.app", (Path(d) / "app-identities.json").read_text())
        self.assertTrue(any(c[:2] == ["apps", "pull"] and bundle in c for c in calls))
        self.assertFalse(any(lab.LAB_BUNDLE in c for c in calls))

    def test_multiple_canvas_apps_require_explicit_selection(self):
        apps = [{"bundle": "a.preview", "name": "ReedleDeviceLab"},
                {"bundle": "b.preview", "name": "ReedlesCanvas"}]
        with self.assertRaisesRegex(ValueError, "Multiple"):
            lab.select_lab_bundle(apps)
        self.assertEqual(lab.select_lab_bundle(apps, "b.preview"), "b.preview")
        self.assertEqual(lab.select_lab_bundle([{"bundle": "com.apple.Playgrounds", "name": "Playgrounds"}]), lab.LAB_BUNDLE)

    def test_source_transfer_requires_verified_playgrounds_identity(self):
        self.assertEqual(lab.select_playgrounds_bundle([{"bundle": "com.apple.actual.playgrounds", "name": "Swift Playgrounds"}]),
                         "com.apple.actual.playgrounds")
        with self.assertRaisesRegex(ValueError, "not transferred"):
            lab.select_playgrounds_bundle([])
        image = {"bundle": "com.apple.ImagePlayground", "name": "Image Playground"}
        with self.assertRaises(ValueError): lab.select_playgrounds_bundle([image])
        apps = {image["bundle"]: {"CFBundleDisplayName": image["name"]},
                "com.apple.actual.playgrounds": {"CFBundleDisplayName": "Swift Playgrounds"}}
        identities = lab.related_app_identities({"returncode": 0, "stdout": json.dumps(apps)})
        self.assertEqual([a["bundle"] for a in identities], ["com.apple.actual.playgrounds"])

    def analyze(self, contents):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "AppModule.ips"
            path.write_text(contents, encoding="utf-8")
            before = path.read_bytes()
            result = lab.analyze_crash(path)
            self.assertEqual(path.read_bytes(), before, "Triage must preserve original bytes")
            self.assertFalse(result["root_cause_confirmed"])
            return result

    def test_two_object_ips_keeps_exception_termination_and_faulting_thread_zero(self):
        header = {"bug_type": "309", "app_name": "AppModule"}
        body = {"procName": "AppModule", "faultingThread": 0,
                "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"},
                "termination": {"namespace": "SIGNAL", "code": 11},
                "threads": [{"frames": [{"imageIndex": 0, "imageOffset": 256, "symbol": "example_crash"}]},
                            {"frames": [{"symbol": "unrelated_thread"}]}],
                "usedImages": [{"name": "PencilKit", "arch": "arm64e", "path": "/private/secret-path"}]}
        result = self.analyze(json.dumps(header) + "\n" + json.dumps(body))
        self.assertEqual(result["faulting_thread"], 0)
        self.assertEqual(result["exception"]["type"], "EXC_BAD_ACCESS")
        self.assertEqual(result["termination"]["code"], 11)
        self.assertEqual(result["faulting_stack"][0]["image"]["name"], "PencilKit")
        self.assertNotIn("secret-path", json.dumps(result))
        self.assertNotIn("unrelated_thread", json.dumps(result))

    def test_triggered_thread_without_index_and_unsymbolicated_stack(self):
        result = self.analyze(json.dumps({"threads": [{"triggered": True, "frames": [{"imageOffset": 1024}]}]}))
        self.assertTrue(result["stack_available"])
        self.assertEqual(result["symbolicated_frames"], 0)

    def test_jetsam_largest_process_is_not_app_termination_evidence(self):
        body = {"bug_type": "298", "largestProcess": "AppModule", "memoryStatus": {}, "pageSize": 16384,
                "processes": [{"name": "AppModule", "rpages": 8000},
                              {"name": "PrivateApp", "reason": "per-process-limit"}]}
        result = self.analyze(json.dumps(body))
        self.assertFalse(result["termination_evidence"])
        self.assertNotIn("PrivateApp", json.dumps(result))
        body["processes"][0]["reason"] = "per-process-limit"
        self.assertTrue(self.analyze(json.dumps(body))["termination_evidence"])

    def test_apple_image_playground_is_not_swift_playgrounds(self):
        report = {"bug_type": "298", "memoryStatus": {}, "processes": [
            {"name": "ImagePlaygroundPosterExtension", "reason": "per-process-limit"},
            {"name": "imageplaygroundd", "reason": "vm-pageshortage"},
            {"name": "Swift Playground", "states": ["suspended"], "rpages": 24}]}
        result = self.analyze(json.dumps(report))
        self.assertEqual([p["name"] for p in result["related_processes"]], ["Swift Playground"])
        self.assertFalse(result["termination_evidence"])
        self.assertEqual(lab.select_crash_reports(["ImagePlayground-2026-11-22.ips"], date(2026, 11, 22)), [])

    def test_legacy_crash_stack_and_missing_stack_are_distinct(self):
        text = "Process: AppModule [123]\nException Type: EXC_CRASH (SIGABRT)\nTermination Reason: SIGNAL 6\nCrashed Thread: 0\n\nThread 0 Crashed:\n0 PencilKit 0x0001 example\n1 AppModule 0x0002 main\n\nThread 1:\n0 unrelated 0x0003\n"
        result = self.analyze(text)
        self.assertEqual(len(result["faulting_stack"]), 2)
        self.assertTrue(result["stack_available"])
        self.assertFalse(self.analyze("{} ")["stack_available"])
        self.assertEqual(self.analyze("unrecognized console text")["parse_status"], "unsupported")

    def test_offline_analysis_needs_no_usb_and_does_not_change_original(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "original.ips"
            path.write_bytes(b'{"exception":{"type":"EXC_CRASH"}}')
            before = path.read_bytes()
            with patch.object(lab, "command") as command, patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(lab.main(["analyze-crash", "--report", str(path), "--output", str(Path(d) / "results")]), 0)
            command.assert_not_called()
            self.assertEqual(path.read_bytes(), before)

    def test_synced_report_fallback_preserves_originals_and_ignores_other_apps(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "synced"; root.mkdir()
            output = Path(d) / "results"; output.mkdir()
            private = root / "PrivateApp-2026-11-22.ips"; private.write_text('{}')
            report = root / "AppModule-2026-11-22.ips"; report.write_text('{"exception":{"type":"EXC_CRASH"}}')
            before = report.read_bytes()
            with patch.object(lab, "command") as command:
                result = lab.collect_synced_crashes(output, root, date(2026, 11, 22))
            command.assert_not_called()
            self.assertEqual(result["copied"], 1)
            self.assertEqual(report.read_bytes(), before)
            self.assertTrue(private.exists())
            self.assertNotIn("PrivateApp", (output / "synced-crash-analysis.json").read_text())


if __name__ == "__main__":
    unittest.main()
