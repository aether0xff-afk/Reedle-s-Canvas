import importlib
import json
from pathlib import Path
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
