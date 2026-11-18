import tempfile
import unittest
import httpx
from fastapi.testclient import TestClient
from test_backend import sample_audio, connect_test_grant, HEADERS

class MetricsAPITests(unittest.TestCase):
    def test_metrics_count_one_request_and_two_provider_attempts_for_auth_retry(self):
        from app import create_app
        from test_oauth import jwt
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def upstream(request):
                if request.url.path == '/oauth/token':
                    return httpx.Response(200,json={'access_token':jwt(account='new'),'refresh_token':'rotated'})
                calls.append(request)
                return httpx.Response(401) if len(calls)==1 else httpx.Response(200,json={'text':'test transcript'})
            app=create_app(state_dir=directory,transport=httpx.MockTransport(upstream))
            connect_test_grant(app)
            with TestClient(app) as client:
                self.assertEqual(client.post('/api/transcribe',content=sample_audio(1.5),headers=HEADERS).status_code,200)
                response=client.get('/api/metrics')
                self.assertEqual(response.status_code,200)
                snapshot=response.json()
                self.assertEqual(snapshot['totals']['successful'],1)
                self.assertEqual(snapshot['totals']['provider_calls'],2)
                self.assertAlmostEqual(snapshot['totals']['submitted_audio_seconds'],3)
                self.assertAlmostEqual(snapshot['totals']['successful_audio_seconds'],1.5)
                self.assertNotIn('test transcript',response.text)
                self.assertIsNone(snapshot['quota']['tokens'])

    def test_failures_count_without_inventing_provider_calls_and_survive_reload(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            app=create_app(state_dir=directory)
            with TestClient(app) as client:
                self.assertEqual(client.post('/api/transcribe',content=b'bad',headers=HEADERS).status_code,422)
                result=client.get('/api/metrics').json()
                self.assertEqual(result['totals']['requests'],1)
                self.assertEqual(result['totals']['failed'],1)
                self.assertEqual(result['totals']['provider_calls'],0)
            with TestClient(create_app(state_dir=directory)) as client:
                self.assertEqual(client.get('/api/metrics').json()['totals']['failed'],1)
