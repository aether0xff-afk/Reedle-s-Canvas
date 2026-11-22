"""Build the standalone laptop/iPad lab kit without credentials or virtual environments."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def build(output: Path) -> dict:
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT))
    app = io.BytesIO()
    with zipfile.ZipFile(app, 'w', zipfile.ZIP_DEFLATED) as z:
        prefix = 'ReedlesCanvas-DeviceLab.swiftpm/'
        package = (ROOT / 'tools/playgrounds/Package.swift').read_text(encoding='utf-8')
        package = package.replace('dev.aether.reedlescanvas', 'dev.aether.reedlescanvas.devicelab')
        package = package.replace('name: "ReedlesCanvas"', 'name: "ReedleDeviceLab"')
        z.writestr(prefix + 'Package.swift', package)
        for p in sorted((ROOT / 'ReedlesCanvas').rglob('*.swift')):
            if p.name == 'ReedlesCanvasApp.swift': continue
            z.write(p, prefix + p.relative_to(ROOT / 'ReedlesCanvas').as_posix())
        z.write(ROOT / 'tools/playgrounds/DeviceLabApp.swift', prefix + 'DeviceLabApp.swift')
        z.writestr(prefix + 'DeviceLabBuildInfo.swift', f'enum DeviceLabBuildInfo {{ static let sourceCommit = "{commit}" }}\n')
    files = {'ReedlesCanvas-DeviceLab.swiftpm.zip': app.getvalue(),
             'START-HERE.md': (ROOT / 'docs/laptop-device-tests.md').read_bytes(),
             'KIT-VERIFICATION.json': (ROOT / 'evaluation/results/device-lab-2026-11-22.json').read_bytes()}
    for name in ['runner.py', 'pyproject.toml', 'uv.lock', 'Start-Reedle-Tests.ps1', 'Run-Tests.cmd',
                 'Collect-Results.cmd', 'Import-Results.cmd']:
        files[name] = (ROOT / 'tools/device_lab' / name).read_bytes()
    manifest = {'schema_version': 1, 'source_commit': commit, 'tracked_changes_present': dirty,
                'files': [{'path': n, 'bytes': len(b), 'sha256': hashlib.sha256(b).hexdigest()} for n, b in files.items()]}
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items(): z.writestr(name, data)
        z.writestr('manifest.json', json.dumps(manifest, indent=2) + '\n')
    return {'zip': str(output.resolve()), 'bytes': output.stat().st_size,
            'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), **manifest}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/Reedle-Laptop-DeviceLab.zip')
    args = parser.parse_args()
    print(json.dumps(build(args.output), indent=2))
