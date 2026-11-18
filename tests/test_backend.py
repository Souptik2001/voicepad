import io
import tempfile
import unittest
import wave
from pathlib import Path

import httpx
from fastapi.testclient import TestClient
from test_oauth import jwt


def sample_audio(seconds=1.5):
    import math
    import struct
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as writer:
        writer.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        writer.writeframes(b''.join(struct.pack('<h', int(3000 * math.sin(n / 10))) for n in range(int(16000 * seconds))))
    return buffer.getvalue()


HEADERS = {'Content-Type': 'audio/wav', 'X-Requested-With': 'voicepad'}


def connect_test_grant(app):
    app.state.auth.persist({'access_token': jwt(), 'refresh_token': 'test-refresh'})


class HealthTests(unittest.TestCase):
    def test_status_is_keyless_and_old_snapshot_is_never_imported(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'codex.json').write_text('{"access_token":"legacy-must-not-be-used","account_id":"old"}')
            with TestClient(create_app(state_dir=root)) as client:
                self.assertEqual(client.get('/healthz').status_code, 200)
                result = client.get('/api/status')
                self.assertEqual(result.status_code, 200)
                self.assertFalse(result.json()['credential_available'])
                self.assertNotIn('legacy-must-not-be-used', result.text)
                self.assertEqual(result.json()['quota'], 'Not reported by provider')


class TranscriptionTests(unittest.TestCase):
    def test_real_audio_normalizes_and_forwards_without_paid_fallback(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def upstream(request):
                calls.append(request)
                self.assertEqual(str(request.url), 'https://chatgpt.com/backend-api/transcribe')
                self.assertIn(b'RIFF', request.content)
                self.assertIn(b'name="file"', request.content)
                self.assertNotIn(b'name="model"', request.content)
                return httpx.Response(200, json={'text':'Hello from test transport.', 'asset_ttl':'30d'})
            app = create_app(state_dir=directory, transport=httpx.MockTransport(upstream))
            connect_test_grant(app)
            with TestClient(app) as client:
                response = client.post('/api/transcribe', content=sample_audio(), headers=HEADERS)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()['text'], 'Hello from test transport.')
            self.assertIsNone(response.json()['usage'])
            self.assertAlmostEqual(response.json()['audio_seconds'], 1.5, places=1)
            self.assertEqual(len(calls), 1)

    def test_unauthorized_audio_refreshes_once_then_retries_only_with_new_token(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def upstream(request):
                calls.append(request)
                if request.url.path == '/oauth/token':
                    return httpx.Response(200, json={'access_token': jwt(account='new-account'), 'refresh_token':'rotated'})
                return httpx.Response(401) if len(calls) == 1 else httpx.Response(200,json={'text':'Recovered'})
            app = create_app(state_dir=directory, transport=httpx.MockTransport(upstream))
            connect_test_grant(app)
            with TestClient(app) as client:
                response = client.post('/api/transcribe',content=sample_audio(),headers=HEADERS)
            self.assertEqual(response.status_code,200,response.text)
            self.assertEqual(response.json()['text'],'Recovered')
            self.assertEqual(len(calls),3)
            self.assertNotEqual(calls[0].headers['authorization'],calls[2].headers['authorization'])


class BoundaryTests(unittest.TestCase):
    def test_rejects_unsafe_audio_before_provider(self):
        from app import create_app, MAX_BYTES
        with tempfile.TemporaryDirectory() as directory:
            def forbidden(request):
                self.fail('Invalid request reached provider')
            with TestClient(create_app(state_dir=directory,transport=httpx.MockTransport(forbidden))) as client:
                self.assertEqual(client.post('/api/transcribe',content=b'bad').status_code,403)
                self.assertEqual(client.post('/api/transcribe',content=b'bad',headers={**HEADERS,'Origin':'https://evil.example'}).status_code,403)
                self.assertEqual(client.post('/api/transcribe',content=b'bad',headers={**HEADERS,'Content-Type':'text/plain'}).status_code,415)
                self.assertEqual(client.post('/api/transcribe',content=b'',headers=HEADERS).status_code,400)
                self.assertEqual(client.post('/api/transcribe',content=b'x'*(MAX_BYTES+1),headers=HEADERS).status_code,413)
                self.assertEqual(client.post('/api/transcribe',content=b'bad',headers=HEADERS).status_code,422)

    def test_provider_errors_sanitized_without_paid_fallback(self):
        from app import create_app
        for upstream_status, expected in [(403,502),(429,429),(500,502)]:
            with tempfile.TemporaryDirectory() as directory:
                calls=[]
                def upstream(request):
                    calls.append(request)
                    return httpx.Response(upstream_status,text='provider secret-test-token HTML')
                app=create_app(state_dir=directory,transport=httpx.MockTransport(upstream))
                connect_test_grant(app)
                with TestClient(app) as client:
                    response=client.post('/api/transcribe',content=sample_audio(),headers=HEADERS)
                self.assertEqual(response.status_code,expected)
                self.assertNotIn('secret-test-token',response.text)
                self.assertEqual(len(calls),1)


class LimitsTests(unittest.TestCase):
    def test_short_and_long_audio_never_reaches_provider(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            def forbidden(request):
                self.fail('Out-of-range clip reached provider')
            with TestClient(create_app(state_dir=directory,transport=httpx.MockTransport(forbidden))) as client:
                for duration in [0.5,601]:
                    response=client.post('/api/transcribe',content=sample_audio(duration),headers=HEADERS)
                    self.assertEqual(response.status_code,422)
                    self.assertEqual(response.json()['code'],'duration_limit')

    def test_busy_rejects_second_recording(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            app=create_app(state_dir=directory)
            app.state.busy=True
            with TestClient(app) as client:
                response=client.post('/api/transcribe',content=sample_audio(),headers=HEADERS)
                self.assertEqual(response.status_code,429)


class StaticTests(unittest.TestCase):
    def test_module_javascript_mime_no_store(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            with TestClient(create_app(state_dir=directory)) as client:
                response=client.get('/core.mjs')
                self.assertEqual(response.status_code,200)
                self.assertIn('javascript',response.headers['content-type'])
                self.assertEqual(response.headers['cache-control'],'no-store')


if __name__ == '__main__':
    unittest.main()
