"""Compile and capture the normal iPad app; no XCTest or provider calls."""
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/app-preview'


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    choices = []
    for runtime, devices in inventory['devices'].items():
        suffix = runtime.rsplit('.', 1)[-1].split('-')
        if suffix[0] != 'iOS': continue
        try: version = tuple(int(v) for v in suffix[1:])
        except ValueError: continue
        if not version or version[0] < 17: continue
        for device in devices:
            if 'iPad' in device.get('deviceTypeIdentifier', ''):
                choices.append((device['state'] == 'Booted', version, device['name'], device['udid']))
    if not choices: raise RuntimeError('No available iPad simulator runtime')
    booted, version, name, udid = max(choices)
    run(['xcodegen', 'generate'])
    if not booted: run(['xcrun', 'simctl', 'boot', udid])
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
    derived = ROOT / '.build/app-preview-build'
    log_path = OUT / 'build.log'
    try:
        with log_path.open('w') as log:
            run(['xcodebuild', '-project', 'ReedlesCanvas.xcodeproj', '-scheme', 'ReedlesCanvas',
                 '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                 '-destination', f'platform=iOS Simulator,id={udid}', '-derivedDataPath', str(derived),
                 'CODE_SIGNING_ALLOWED=NO', 'build'], stdout=log, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError:
        print('\n'.join(log_path.read_text(errors='replace').splitlines()[-60:]), flush=True)
        raise
    app = derived / 'Build/Products/Debug-iphonesimulator/ReedlesCanvas.app'
    run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '09:41', '--batteryState', 'charged', '--batteryLevel', '100'])
    run(['xcrun', 'simctl', 'install', udid, str(app)])
    run(['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, 'dev.aether.reedlescanvas'])
    time.sleep(4)
    screenshot = OUT / 'normal-app.png'
    run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(screenshot)])
    run(['xcrun', 'simctl', 'ui', udid, 'appearance', 'dark'])
    time.sleep(1)
    run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(OUT / 'normal-app-dark.png')])
    # Derived build products are not a signed physical-device IPA and are not the deliverable.
    metadata = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'created_utc': datetime.now(timezone.utc).isoformat(), 'device': name,
                'os_version': '.'.join(map(str, version)), 'build_succeeded': True,
                'tests_executed': False, 'provider_calls': 0, 'screenshot': screenshot.name,
                'dark_screenshot': 'normal-app-dark.png'}
    (OUT / 'preview.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(metadata), flush=True)


if __name__ == '__main__': main()
