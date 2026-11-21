"""Run the platform-independent Swift tests on Linux (requires swiftc and libsqlite3-dev)."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sqlite-module", type=Path,
                        help="directory containing an existing SQLite3 module map and library")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    tutor_models = ["TutorActions", "TutorMath", "TutorCapture"]
    tutor_sources = tutor_models + ["TutorGateway"]
    store_sources = ["CanvasCamera", "NoteStore", "StrokeOrder", "NoteResource", "PracticeEngine", "TutorPlacement"] + tutor_models
    suites = {
        "CanvasCameraTests": ["CanvasCamera", "CanvasWindow"],
        "StrokeIdentityLedgerTests": ["StrokeIdentityLedger"],
        "NoteStoreTests": store_sources,
        "NoteResourceStoreTests": store_sources,
        "TutorLayerTests": store_sources,
        "TutorCaptureTests": tutor_sources,
        "TutorMathTests": ["TutorMath"],
        "PracticeEngineTests": tutor_models + ["PracticeEngine"],
    }
    with tempfile.TemporaryDirectory(prefix="reedle-core-") as temp:
        work = Path(temp)
        module = args.sqlite_module or work
        if args.sqlite_module is None:
            (work / "sqlite-shim.h").write_text("#include <sqlite3.h>\n", encoding="utf-8")
            (work / "module.modulemap").write_text(
                'module SQLite3 [system] { header "sqlite-shim.h" link "sqlite3" export * }\n',
                encoding="utf-8",
            )
        for suite, sources in suites.items():
            binary = work / suite
            command = ["swiftc", "-swift-version", "5", "-O"]
            if "NoteStore" in sources:
                command += ["-I", str(module), "-L", str(module)]
            command += [str(root / "ReedlesCanvas" / f"{name}.swift") for name in sources]
            command += [str(root / "ReedlesCanvasTests" / f"{suite}.swift"), "-o", str(binary)]
            subprocess.run(command, check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
