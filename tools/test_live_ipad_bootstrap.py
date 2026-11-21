import base64
from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import httpx

from tools import run_live_ipad as bootstrap


class SealedCredentialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory=TemporaryDirectory(prefix='reedle-bootstrap-test-')
        cls.work=Path(cls.directory.name)
        with patch.object(bootstrap,'WORK',cls.work), patch.dict(bootstrap.os.environ,{'GITHUB_RUN_ID':'123','GITHUB_SHA':'a'*40}):
            with redirect_stdout(StringIO()): bootstrap.prepare()
        cls.public=json.loads((cls.work/'public-key.json').read_bytes())
        (cls.work/'public.pem').write_text(cls.public['public_key'],encoding='ascii')

    @classmethod
    def tearDownClass(cls): cls.directory.cleanup()

    def packet(self,value=b'test-only-provider-credential'):
        encrypted=bootstrap.openssl('pkeyutl','-encrypt','-pubin','-inkey',self.work/'public.pem',
            '-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha256','-pkeyopt','rsa_mgf1_md:sha256',data=value)
        return {'run_id':self.public['run_id'],'key_id':self.public['key_id'],
                'ciphertext':base64.b64encode(encrypted).decode('ascii')}

    def test_real_oaep_round_trip_without_plaintext_in_packet(self):
        packet=self.packet()
        self.assertNotIn('test-only-provider-credential',json.dumps(packet))
        self.assertEqual(bootstrap.decrypt(packet,self.public,self.work/'wrapping-key.pem'),
                         'test-only-provider-credential')

    def test_other_run_or_key_is_rejected(self):
        for name in ('run_id','key_id'):
            with self.subTest(name=name):
                packet=self.packet()
                packet[name]='other'
                with self.assertRaises(ValueError): bootstrap.decrypt(packet,self.public,self.work/'wrapping-key.pem')

    def test_malformed_ciphertexts_are_rejected(self):
        for value in ('not-base64','A'*2048,base64.b64encode(b'bad').decode()):
            with self.subTest(size=len(value)):
                packet={**self.packet(),'ciphertext':value}
                with self.assertRaises(ValueError): bootstrap.decrypt(packet,self.public,self.work/'wrapping-key.pem')

    def test_tampered_ciphertext_cannot_be_decrypted(self):
        packet=self.packet()
        raw=bytearray(base64.b64decode(packet['ciphertext']))
        raw[50]^=1
        packet['ciphertext']=base64.b64encode(raw).decode()
        with self.assertRaises(RuntimeError): bootstrap.decrypt(packet,self.public,self.work/'wrapping-key.pem')

    def test_invalid_plaintext_is_not_accepted_as_a_token(self):
        for value in (b'',b'contains\nnewline',b'contains space'):
            with self.subTest(value=value):
                with self.assertRaises(ValueError): bootstrap.decrypt(self.packet(value),self.public,self.work/'wrapping-key.pem')

    def test_delivery_retries_temporary_failure_then_decrypts_the_bound_packet(self):
        statuses=iter([503,404,200])
        packet=self.packet()
        seen=[]
        def respond(request):
            seen.append(request.url.host)
            status=next(statuses)
            return httpx.Response(status,json=packet if status==200 else {})
        client=httpx.Client(transport=httpx.MockTransport(respond))
        with patch.object(bootstrap,'WORK',self.work), patch.dict(bootstrap.os.environ,
                {'GITHUB_REPOSITORY':'aether0xff-afk/Reedle-s-Canvas','GITHUB_REF':'refs/heads/codex/canvas-camera'}), \
                patch.object(bootstrap.httpx,'Client',return_value=client),patch.object(bootstrap,'sleep'):
            self.assertEqual(bootstrap.wait_for_credential(),'test-only-provider-credential')
        self.assertEqual(seen,['raw.githubusercontent.com']*3)

    def test_another_repository_is_rejected_before_fetching_any_packet(self):
        with patch.object(bootstrap,'WORK',self.work),patch.dict(bootstrap.os.environ,
                {'GITHUB_REPOSITORY':'other/repo','GITHUB_REF':'refs/heads/codex/canvas-camera'}), \
                patch.object(bootstrap.httpx,'Client') as client:
            with self.assertRaises(RuntimeError): bootstrap.wait_for_credential()
            client.assert_not_called()

    def test_failure_removes_local_private_key_and_test_resource(self):
        with TemporaryDirectory(prefix='reedle-bootstrap-cleanup-') as folder:
            root=Path(folder)
            work=root/'.build/live-ipad'
            work.mkdir(parents=True)
            fixture=root/'ReedlesCanvasTests/LiveGateway.json'
            fixture.parent.mkdir()
            fixture.write_text('test fixture')
            (work/'wrapping-key.pem').write_text('temporary test material')
            with patch.object(bootstrap,'ROOT',root),patch.object(bootstrap,'WORK',work), \
                 patch.object(bootstrap,'wait_for_credential',side_effect=TimeoutError),redirect_stdout(StringIO()):
                with self.assertRaises(TimeoutError): bootstrap.run()
            self.assertFalse(fixture.exists())
            self.assertFalse((work/'wrapping-key.pem').exists())


if __name__=='__main__': unittest.main()
