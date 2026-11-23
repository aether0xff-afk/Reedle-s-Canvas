"""Export a private app connection profile; credentials are read from environment only."""
import argparse
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def default_output() -> Path:
    if os.name == 'nt':
        return Path(os.environ['LOCALAPPDATA']) / 'ReedlesCanvas/tutor-connection.json'
    return Path.home() / '.local/share/ReedlesCanvas/tutor-connection.json'


def server_address(value: str) -> str:
    value = value.strip()
    try:
        address = urlsplit(value)
        valid = (len(value.encode('utf-8')) <= 2048 and address.scheme == 'https'
                 and address.hostname and address.username is None and address.password is None
                 and '?' not in value and '#' not in value and not any(c.isspace() for c in value)
                 and not any(ord(c) < 33 or ord(c) == 127 for c in value)
                 and '\\' not in value)
        # Force urllib to reject malformed ports as well as malformed IPv6 hosts.
        address.port
    except ValueError:
        valid = False
    if not valid:
        raise ValueError('Supply a valid HTTPS tutor server URL without credentials, query or fragment.')
    return value


def app_token() -> str:
    token = os.environ.get('REEDLE_CLIENT_TOKEN', '')
    if token.lower().startswith('baze_') or (token and token == os.environ.get('BAZE_API_KEY')):
        raise ValueError('Use a separate REEDLE_CLIENT_TOKEN, never the BAZE provider key.')
    if not token or len(token) > 512 or not all(33 <= ord(c) <= 126 for c in token):
        raise ValueError('Configure REEDLE_CLIENT_TOKEN as a nonempty ASCII token of at most 512 bytes.')
    return token


def restrict_file(path: Path, fd: int) -> None:
    if os.name != 'nt':
        os.fchmod(fd, 0o600)
        return
    identity = subprocess.check_output(['whoami', '/user', '/fo', 'csv', '/nh'], text=True)
    row = next(csv.reader(identity.splitlines()), [])
    sid = next((v for v in row if re.fullmatch(r'S-1-\d+(?:-\d+)+', v)), None)
    if sid is None:
        raise ValueError('Unable to determine the current Windows account for private file permissions.')
    subprocess.run(['icacls', str(path), '/inheritance:r', '/grant:r', f'*{sid}:(F)'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def export(server: str, output: Path, replace: bool) -> Path:
    content = (json.dumps({'format': 'reedle.tutor.connection', 'version': 1,
                          'server': server_address(server), 'access_token': app_token()},
                         ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    if len(content) > 8192:
        raise ValueError('Connection profile exceeds 8 KiB.')
    output = output.expanduser().resolve()
    if output == ROOT or ROOT in output.parents:
        raise ValueError('Save the credential-bearing profile outside the source checkout.')
    if output.exists() and not replace:
        raise ValueError('The output already exists; use --replace only to replace that profile.')
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.reedle-connection-', suffix='.tmp', dir=output.parent)
    temporary = Path(name)
    try:
        restrict_file(temporary, fd)  # No credential bytes exist before permissions are restricted.
        with os.fdopen(fd, 'wb') as stream:
            fd = -1
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(temporary, output)
        else:
            # A hard link publishes complete bytes atomically and refuses an existing path.
            os.link(temporary, output)
            temporary.unlink()
    finally:
        if fd != -1:
            os.close(fd)
        temporary.unlink(missing_ok=True)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', required=True)
    parser.add_argument('--output', type=Path, default=default_output())
    parser.add_argument('--replace', action='store_true')
    args = parser.parse_args()
    try:
        path = export(args.server, args.output, args.replace)
    except (ValueError, OSError, subprocess.SubprocessError):
        # Never echo the URL, environment values or subprocess output on failure.
        parser.exit(1, 'Connection export failed. Check the HTTPS URL, app token, private output path and permissions.\n')
    print(f'Private connection profile saved: {path}')
    print('Transfer privately to your iPad. Import in Tutor settings, choose usage and Save.')


if __name__ == '__main__':
    main()
