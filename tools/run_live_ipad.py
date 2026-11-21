"""Run native iPad tests with a per-run sealed BAZE credential and a local TLS gateway.

Only the public wrapping key is uploaded. The provider credential is decrypted into
memory and passed only to the gateway child, never to xcodebuild or the test app.
"""
import argparse
import base64
from hashlib import sha256
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
from time import monotonic, sleep, time

import httpx

try:
    from . import test_ipad
except ImportError:
    import test_ipad


ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.build' / 'live-ipad'


def openssl(*args, data=None):
    result = subprocess.run(['openssl', *map(str,args)], input=data, capture_output=True)
    if result.returncode:
        raise RuntimeError('OpenSSL test credential operation failed')
    return result.stdout


def prepare():
    WORK.mkdir(parents=True,exist_ok=True)
    key = WORK/'wrapping-key.pem'
    openssl('genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:3072','-out',key)
    key.chmod(0o600)
    public = openssl('pkey','-in',key,'-pubout')
    info={'run_id':os.environ['GITHUB_RUN_ID'],'head_sha':os.environ['GITHUB_SHA'],
          'public_key':public.decode('ascii'),'key_id':sha256(public).hexdigest()}
    (WORK/'public-key.json').write_text(json.dumps(info)+'\n',encoding='utf-8')
    print('Prepared an ephemeral public wrapping key; private key stays on this runner.',flush=True)


def decrypt(packet, public, key):
    if (not isinstance(packet,dict) or set(packet)!={'run_id','key_id','ciphertext'}
            or packet['run_id']!=public['run_id'] or packet['key_id']!=public['key_id']):
        raise ValueError('Sealed credential is bound to another test run')
    encoded=packet['ciphertext']
    if not isinstance(encoded,str) or len(encoded)>1024:
        raise ValueError('Invalid sealed credential size')
    encrypted=base64.b64decode(encoded,validate=True)
    if len(encrypted)!=384:
        raise ValueError('Invalid sealed credential size')
    value=openssl('pkeyutl','-decrypt','-inkey',key,'-pkeyopt','rsa_padding_mode:oaep',
                  '-pkeyopt','rsa_oaep_md:sha256','-pkeyopt','rsa_mgf1_md:sha256',data=encrypted)
    if not 1<=len(value)<=4096 or any(not 33<=c<=126 for c in value):
        raise ValueError('Invalid decrypted credential')
    return value.decode('ascii')


def wait_for_credential():
    public=json.loads((WORK/'public-key.json').read_bytes())
    repository=os.environ['GITHUB_REPOSITORY']
    if repository!='aether0xff-afk/Reedle-s-Canvas' or os.environ['GITHUB_REF']!='refs/heads/codex/canvas-camera':
        raise RuntimeError('Live bootstrap is restricted to the designated development branch')
    endpoint=f'https://raw.githubusercontent.com/{repository}/codex/canvas-camera/ci/live-key/{public["run_id"]}.json'
    deadline=monotonic()+900
    print('Waiting for the credential sealed to this run; maximum 15 minutes.',flush=True)
    with httpx.Client(timeout=15,follow_redirects=False) as client:
        while monotonic()<deadline:
            try:
                response=client.get(endpoint,params={'revision':int(time())})
            except httpx.TransportError:
                sleep(5)
                continue
            if response.status_code==200:
                if len(response.content)>2048:
                    raise ValueError('Oversized sealed credential')
                return decrypt(response.json(),public,WORK/'wrapping-key.pem')
            if response.status_code not in (404,408,429) and response.status_code<500:
                raise RuntimeError('Could not retrieve the sealed test credential')
            sleep(5)
    raise TimeoutError('The sealed test credential was not delivered')


def run():
    server=None
    fixture=ROOT/'ReedlesCanvasTests'/'LiveGateway.json'
    logs=ROOT/'.build'/'ipad-tests'
    logs.mkdir(parents=True,exist_ok=True)
    try:
        provider_key=wait_for_credential()
        cert,cert_key=WORK/'loopback.pem',WORK/'loopback.key'
        config=WORK/'tls.cnf'
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n'
                          'default_md=sha256\n[dn]\nCN=127.0.0.1\n[v3]\n'
                          'subjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n'
                          'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n',encoding='ascii')
        openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',config,
                '-keyout',cert_key,'-out',cert)
        cert_key.chmod(0o600)
        devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))['devices']
        udid=test_ipad.ipad_identifier(devices)
        device=next(d for group in devices.values() for d in group if d['udid']==udid)
        if device['state']!='Booted': subprocess.run(['xcrun','simctl','boot',udid],check=True)
        subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],check=True,timeout=240)
        subprocess.run(['xcrun','simctl','keychain',udid,'add-root-cert',str(cert)],check=True)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0))
            port=listener.getsockname()[1]
        token=secrets.token_urlsafe(32)
        server_env={**os.environ,'BAZE_API_KEY':provider_key,'BAZE_MODEL':'gpt-6.1-terra',
                    'BAZE_BASE_URL':'https://api.baze.co/v1/gateway','REEDLE_CLIENT_TOKEN':token,
                    'REEDLE_BUDGET_DB':str(WORK/'attempts.sqlite3'),'REEDLE_DAILY_ATTEMPT_LIMIT':'6',
                    'REEDLE_PROVIDER_MAX_ATTEMPTS':'1','REEDLE_PROVIDER_TIMEOUT_SECONDS':'20'}
        with (logs/'live-gateway.log').open('w',encoding='utf-8') as gateway_log:
            server=subprocess.Popen([sys.executable,'-m','uvicorn','reedle_server.app:app','--host','127.0.0.1',
                '--port',str(port),'--ssl-certfile',str(cert),'--ssl-keyfile',str(cert_key),'--no-access-log'],
                cwd=ROOT/'server',env=server_env,stdout=gateway_log,stderr=subprocess.STDOUT)
            del server_env,provider_key
            deadline=monotonic()+10
            while True:
                if server.poll() is not None: raise RuntimeError('Local live gateway exited before tests')
                with socket.socket() as probe:
                    if probe.connect_ex(('127.0.0.1',port))==0: break
                if monotonic()>deadline: raise TimeoutError('Local live gateway startup timed out')
                sleep(.1)
            fixture.write_text(json.dumps({'baseURL':f'https://127.0.0.1:{port}','accessToken':token})+'\n',encoding='utf-8')
            fixture.chmod(0o600)
            print('Live native fixture ready. Provider key is confined to the server child.',flush=True)
            return subprocess.call([sys.executable,str(ROOT/'tools/test_ipad.py'),'--device',udid,
                                    '--require-live-gateway'],cwd=ROOT)
    finally:
        if server is not None:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        fixture.unlink(missing_ok=True)
        (WORK/'wrapping-key.pem').unlink(missing_ok=True)
        (WORK/'loopback.key').unlink(missing_ok=True)
        print('Stopped the live gateway and removed temporary decryption keys and app test token.',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['prepare','test'])
    args=parser.parse_args()
    if args.command=='prepare': prepare()
    else: raise SystemExit(run())
