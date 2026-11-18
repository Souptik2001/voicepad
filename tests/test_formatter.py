import json
import tempfile
import unittest
import httpx
from fastapi.testclient import TestClient
from test_backend import HEADERS, sample_audio, connect_test_grant


def stream_response(text='Hello John. Thanks.',usage=None,complete=True):
    events=[{'type':'response.output_text.delta','delta':text}]
    if complete:events.append({'type':'response.completed','response':{'usage':usage or {'input_tokens':120,'output_tokens':8,'total_tokens':128}}})
    return httpx.Response(200,text=''.join('data: '+json.dumps(e)+'\n\n' for e in events),headers={'Content-Type':'text/event-stream'})

class FormatterTests(unittest.TestCase):
    def test_empty_instructions_use_audio_only_and_invalid_slot_does_not_send(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            calls=[]
            def upstream(request):
                calls.append(request)
                return httpx.Response(200,json={'text':'raw text'})
            app=create_app(state_dir=directory,transport=httpx.MockTransport(upstream));connect_test_grant(app)
            with TestClient(app) as c:
                c.put('/api/profiles/1',headers=HEADERS,json={'name':'Raw','instructions':' \n '})
                for slot in ['0','10','01','x','2']:
                    self.assertEqual(c.post('/api/transcribe',headers={**HEADERS,'X-Voicepad-Profile':slot},content=sample_audio()).status_code,422)
                r=c.post('/api/transcribe',headers={**HEADERS,'X-Voicepad-Profile':'1'},content=sample_audio())
                self.assertEqual(r.status_code,200,r.text)
                self.assertEqual(r.json()['text'],'raw text')
                self.assertEqual(len(calls),1)
                self.assertFalse(r.json()['formatted'])

    def test_instructions_are_separate_from_dictation_and_return_formatted_output(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            calls=[]
            def upstream(request):
                calls.append(request)
                if request.url.path.endswith('/transcribe'):return httpx.Response(200,json={'text':'um hi john thanks'})
                body=json.loads(request.content)
                self.assertEqual(body['model'],'gpt-5.6-luna')
                self.assertFalse(body['store']);self.assertTrue(body['stream'])
                self.assertIn('dictated',body['instructions'])
                self.assertEqual(body['input'][0]['role'],'developer')
                self.assertEqual(body['input'][0]['content'][0]['text'],'Professional punctuation.')
                self.assertEqual(body['input'][1]['content'][0]['text'],'um hi john thanks')
                self.assertNotIn('tools',body)
                return stream_response()
            app=create_app(state_dir=directory,transport=httpx.MockTransport(upstream));connect_test_grant(app)
            with TestClient(app) as c:
                c.put('/api/profiles/3',headers=HEADERS,json={'name':'Official','instructions':'Professional punctuation.'})
                r=c.post('/api/transcribe',headers={**HEADERS,'X-Voicepad-Profile':'3'},content=sample_audio())
                self.assertEqual(r.status_code,200,r.text)
                self.assertEqual(r.json()['text'],'Hello John. Thanks.')
                self.assertTrue(r.json()['formatted'])
                self.assertEqual(r.json()['profile']['name'],'Official')
                self.assertEqual(r.json()['formatting_usage']['total_tokens'],128)
                self.assertEqual(len(calls),2)
                totals=c.get('/api/metrics').json()
                self.assertEqual(totals['formatting']['totals']['calls'],1)
                self.assertEqual(totals['formatting']['totals']['successful'],1)
                self.assertEqual(totals['formatting']['totals']['input_tokens'],120)
                self.assertEqual(totals['totals']['provider_calls'],1)
                self.assertIsNone(totals['quota']['tokens'])

    def test_formatter_401_refreshes_only_once_and_tokens_persist(self):
        from app import create_app
        from test_oauth import jwt
        with tempfile.TemporaryDirectory() as directory:
            calls=[]
            def upstream(request):
                if request.url.path.endswith('/transcribe'):return httpx.Response(200,json={'text':'raw words'})
                if request.url.path=='/oauth/token':return httpx.Response(200,json={'access_token':jwt(account='new'),'refresh_token':'rotated'})
                calls.append(request)
                return httpx.Response(401) if len(calls)==1 else stream_response()
            app=create_app(state_dir=directory,transport=httpx.MockTransport(upstream));connect_test_grant(app)
            with TestClient(app) as c:
                c.put('/api/profiles/1',headers=HEADERS,json={'name':'A','instructions':'Format it.'})
                r=c.post('/api/transcribe',headers={**HEADERS,'X-Voicepad-Profile':'1'},content=sample_audio())
                self.assertTrue(r.json()['formatted'],r.text)
                self.assertEqual(len(calls),2)
                self.assertNotEqual(calls[0].headers['authorization'],calls[1].headers['authorization'])
            with TestClient(create_app(state_dir=directory)) as c:
                m=c.get('/api/metrics').json()['formatting']['totals']
                self.assertEqual(m['calls'],2);self.assertEqual(m['successful'],1);self.assertEqual(m['total_tokens'],128)

    def test_formatter_failures_keep_raw_text_and_never_return_partial_output(self):
        from app import create_app
        for failure in [httpx.Response(429,text='SECRET provider error'),stream_response('partial',complete=False),httpx.Response(200,text='data: {broken}\n\n')]:
            with tempfile.TemporaryDirectory() as directory:
                def upstream(request):
                    return httpx.Response(200,json={'text':'raw transcript survives'}) if request.url.path.endswith('/transcribe') else failure
                app=create_app(state_dir=directory,transport=httpx.MockTransport(upstream));connect_test_grant(app)
                with TestClient(app) as c:
                    c.put('/api/profiles/1',headers=HEADERS,json={'name':'Official','instructions':'Format it.'})
                    r=c.post('/api/transcribe',headers={**HEADERS,'X-Voicepad-Profile':'1'},content=sample_audio())
                    self.assertEqual(r.status_code,200,r.text)
                    self.assertEqual(r.json()['text'],'raw transcript survives')
                    self.assertFalse(r.json()['formatted']);self.assertIn('raw',r.json()['warning'].lower())
                    self.assertNotIn('SECRET',r.text)
                    self.assertEqual(c.get('/api/metrics').json()['formatting']['totals']['failed'],1)
