"""Build the iPad arm64 app and package an unsigned IPA without running tests."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/ipad-build'


def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    run(['xcodegen', 'generate'])
    derived = ROOT / '.build/ipad-device-build'
    log_path = OUT / 'device-build.log'
    try:
        with log_path.open('w') as log:
            run(['xcodebuild', '-project', 'ReedlesCanvas.xcodeproj', '-scheme', 'ReedlesCanvas',
                 '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
                 '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO',
                 'CODE_SIGNING_REQUIRED=NO', 'EXCLUDED_SOURCE_FILE_NAMES=DeviceLabMetrics.swift DeviceLabView.swift',
                 'build'], stdout=log, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError:
        print('\n'.join(log_path.read_text(errors='replace').splitlines()[-60:]), flush=True)
        raise

    app = derived / 'Build/Products/Release-iphoneos/ReedlesCanvas.app'
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'dev.aether.reedlescanvas' or info.get('UIDeviceFamily') != [2]:
        raise RuntimeError('Unexpected app identity or device family')
    architecture = subprocess.check_output(['lipo', '-archs', str(app / info['CFBundleExecutable'])], text=True).strip()
    if architecture != 'arm64' or (app / '_CodeSignature').exists():
        raise RuntimeError('Expected an unsigned arm64 device build')
    payload = ROOT / '.build/ipad-package/Payload'
    payload.mkdir(parents=True, exist_ok=True)
    run(['ditto', str(app), str(payload / app.name)])
    ipa = OUT / 'ReedlesCanvas-unsigned.ipa'
    run(['ditto', '-c', '-k', '--keepParent', str(payload), str(ipa)])
    metadata = {
        'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'sdk_version': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
        'bundle_identifier': info['CFBundleIdentifier'], 'minimum_os_version': info.get('MinimumOSVersion'),
        'configuration': 'Release', 'platform': 'iPad device', 'architectures': [architecture],
        'build_succeeded': True, 'signed': False, 'direct_device_installable': False,
        'installation_requirement': 'Sign with an Apple development or distribution identity and a matching provisioning profile.',
        'tests_executed': False, 'app_launched': False, 'provider_calls': 0,
        'package': ipa.name, 'bytes': ipa.stat().st_size, 'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest()
    }
    (OUT / 'device-build.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    (OUT / 'READ-ME.txt').write_text(
        'ReedlesCanvas-unsigned.ipa is the Release arm64 build for a physical iPad (iPadOS 17+).\n'
        'It is unsigned and cannot be installed directly. An Apple signing identity and provisioning profile are required.\n'
        'No tests, app launches or BAZE calls were performed. The known physical workload crash remains unconfirmed.\n',
        encoding='utf-8')
    print(json.dumps(metadata), flush=True)


if __name__ == '__main__':
    main()
