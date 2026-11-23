"""Package the normal iPad app from committed sources, excluding device-test tools."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def build(output: Path, compile_only: bool = False) -> dict:
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT):
        raise ValueError('Commit tracked changes before packaging a versioned app.')
    def read(path):
        return subprocess.check_output(['git', 'show', f'{commit}:{path}'], cwd=ROOT)
    sources = subprocess.check_output(['git', 'ls-files', '--', 'ReedlesCanvas'], cwd=ROOT, text=True).splitlines()
    excluded = {'DeviceLabMetrics.swift', 'DeviceLabView.swift'}
    prefix = 'ReedlesCanvas.swiftpm/'
    files = {prefix + 'Package.swift': read('tools/playgrounds/Package.swift')}
    for path in sources:
        if path.endswith('.swift') and Path(path).name not in excluded:
            files[prefix + path.removeprefix('ReedlesCanvas/')] = read(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, content in files.items(): z.writestr(name, content)
    manifest = {'source_commit': commit, 'package': output.name,
                'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                'entry_point': 'ReedlesCanvasApp', 'device_lab_included': False,
                'checks_for_this_update': ('Compile only; app not launched; tests deferred by user' if compile_only
                                           else 'Build and normal-app screenshot only; tests deferred by user'),
                'known_unresolved': ['Device-lab automatic workload crash reported on physical iPad; cause unconfirmed'],
                'files': [{'path': n, 'bytes': len(v), 'sha256': hashlib.sha256(v).hexdigest()} for n, v in files.items()]}
    path = output.with_name('ReedlesCanvas-App-manifest.json')
    path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=ROOT / '.build/ReedlesCanvas-App.swiftpm.zip')
    p.add_argument('--compile-only', action='store_true')
    args = p.parse_args()
    print(json.dumps(build(args.output, args.compile_only), indent=2))
