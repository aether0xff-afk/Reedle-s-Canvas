import io
from contextlib import redirect_stderr
import unittest

from tools.test_ipad import parse_arguments, xcode_test_args


class IPadRunnerTest(unittest.TestCase):
    udid = "00123456-AAAA-BBBB-CCCC-000000000000"

    def test_simulator_preserves_default_signing_and_sdk(self):
        args = parse_arguments(["--device", self.udid])
        command = xcode_test_args(args, self.udid, "/tmp/sample.xcresult")
        self.assertIn("iphonesimulator", command)
        self.assertIn(f"platform=iOS Simulator,id={self.udid}", command)
        self.assertFalse(any("REEDLE_UI_TEST_SUPPORT" in arg or "DEVELOPMENT_TEAM=" in arg for arg in command))
        focused = parse_arguments(["--device", self.udid, "--only-testing", "ReedlesCanvasTests/NotePDFTests"])
        self.assertIn("-only-testing:ReedlesCanvasTests/NotePDFTests", xcode_test_args(focused, self.udid, "/tmp/focused"))

    def test_physical_device_scopes_signing_and_test_data_isolation(self):
        args = parse_arguments(["--physical-device", self.udid, "--team-id", "TESTTEAM01"])
        command = xcode_test_args(args, self.udid, "/tmp/sample.xcresult")
        self.assertNotIn("iphonesimulator", command)
        self.assertIn("iphoneos", command)
        self.assertIn(f"platform=iOS,id={self.udid}", command)
        self.assertIn("DEVELOPMENT_TEAM=TESTTEAM01", command)
        self.assertIn("OTHER_SWIFT_FLAGS=$(inherited) -DREEDLE_UI_TEST_SUPPORT", command)
        self.assertNotIn("-allowProvisioningUpdates", command)

    def test_rejects_conflicting_targets_and_incomplete_signing(self):
        cases = (["--physical-device", self.udid],
                 ["--device", self.udid, "--physical-device", self.udid],
                 ["--device", self.udid, "--team-id", "TESTTEAM01"])
        for argv in cases:
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                parse_arguments(argv)
            self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
