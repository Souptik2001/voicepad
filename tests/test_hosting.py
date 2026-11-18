import tempfile
import unittest
from fastapi.testclient import TestClient
from unittest.mock import patch


class HostingTests(unittest.TestCase):
    def test_clean_install_defaults_to_localhost_origin(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory, patch.dict('os.environ', {'VOICEPAD_PUBLIC_ORIGIN':'http://localhost:8791'}):
            with TestClient(create_app(state_dir=directory)) as c:
                r=c.post('/api/transcribe',headers={'Origin':'http://localhost:8791','X-Requested-With':'voicepad','Content-Type':'audio/wav'},content=b'bad')
                self.assertEqual(r.status_code,422,r.text)

    def test_origin_configuration_is_an_exact_safe_origin(self):
        from app import create_app
        for value in ['https://example.com/path','https://user:password@example.com','https://example.com?x=y','https://example.com#fragment','ftp://example.com','http://remote.example.com','*']:
            with self.subTest(value=value),tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):create_app(state_dir=directory,public_origin=value)
        with tempfile.TemporaryDirectory() as directory:
            app=create_app(state_dir=directory,public_origin='https://voicepad.example.com')
            with TestClient(app,base_url='https://voicepad.example.com') as c:
                self.assertEqual(c.get('/healthz').status_code,200)
                self.assertEqual(c.get('/healthz',headers={'Host':'evil.example'}).status_code,400)
