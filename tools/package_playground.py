"""Package the app's existing Swift sources for Swift Playground on iPad."""

import argparse
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


root = Path(__file__).resolve().parents[1]
app = root / "ReedlesCanvas"
bundle = Path("ReedlesCanvas.swiftpm")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path)
parser.add_argument("--m1-checkpoint", action="store_true", help="open the isolated 10,000-stroke test note")
args = parser.parse_args()
filename = "ReedlesCanvas-M1.zip" if args.m1_checkpoint else f"{bundle}.zip"
archive = args.output or root / ".build" / filename
archive.parent.mkdir(parents=True, exist_ok=True)

with ZipFile(archive, "w", compression=ZIP_DEFLATED) as package:
    package.write(root / "tools" / "playgrounds" / "Package.swift", bundle / "Package.swift")
    for source in sorted(app.rglob("*.swift")):
        entry = source
        if args.m1_checkpoint and source.name == "ReedlesCanvasApp.swift":
            entry = root / "tools" / "playgrounds" / "M1CheckpointApp.swift"
        package.write(entry, bundle / source.relative_to(app))

print(archive)
