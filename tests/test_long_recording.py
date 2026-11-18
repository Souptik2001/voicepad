import io
import tempfile
import unittest
import wave
import httpx
from fastapi.testclient import TestClient
from test_backend import HEADERS, connect_test_grant


def pcm_clip(seconds):
    out=io.BytesIO()
    with wave.open(out,'wb') as w:
        w.setparams((1,2,16000,0,'NONE','not compressed'))
        w.writeframes(b'\0' * round(seconds*32000))
    return out.getvalue()


class LongRecordingTests(unittest.TestCase):
    def test_overlong_clip_is_rejected_not_silently_truncated(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            def forbidden(request):self.fail('Overlong clip reached provider')
            with TestClient(create_app(state_dir=directory,transport=httpx.MockTransport(forbidden))) as c:
                for seconds in [600.5,601,650]:
                    r=c.post('/api/transcribe',headers=HEADERS,content=pcm_clip(seconds))
                    self.assertEqual(r.status_code,422,r.text)
                    self.assertEqual(r.json()['code'],'duration_limit')

    def test_ten_minutes_is_normalized_and_forwarded_without_two_minute_truncation(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            calls=[]
            def provider(request):
                calls.append(request)
                self.assertGreater(len(request.content),19_000_000)
                return httpx.Response(200,json={'text':'Ten-minute transport fixture.'})
            app=create_app(state_dir=directory,transport=httpx.MockTransport(provider))
            connect_test_grant(app)
            with TestClient(app) as client:
                r=client.post('/api/transcribe',headers=HEADERS,content=pcm_clip(600))
                self.assertEqual(r.status_code,200,r.text)
                self.assertEqual(r.json()['audio_seconds'],600)
                self.assertEqual(len(calls),1)
                status=client.get('/api/status').json()
                self.assertEqual(status['max_seconds'],600)
                self.assertEqual(status['max_bytes'],25*1024*1024)
                self.assertEqual(client.get('/api/metrics').json()['totals']['successful_audio_seconds'],600)
