"""Independent review regressions: no live calls or production changes."""
import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient
from test_backend import HEADERS, connect_test_grant


class ReviewTests(unittest.TestCase):
    def request(self, formatter_response, auth_failure=None):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            def upstream(request):
                if request.url.path.endswith('/transcribe'):
                    return httpx.Response(200, json={'text': 'RAW_TRANSCRIPT_MUST_SURVIVE'})
                return formatter_response
            app = create_app(state_dir=directory, transport=httpx.MockTransport(upstream))
            connect_test_grant(app)
            original_credentials = app.state.auth.credentials
            if auth_failure:
                async def credentials(*args, **kwargs):
                    if kwargs.get('force'):
                        raise auth_failure
                    return await original_credentials(*args, **kwargs)
                app.state.auth.credentials = credentials
            with TestClient(app, raise_server_exceptions=False) as client:
                client.put('/api/profiles/1', headers=HEADERS,
                           json={'name': 'Review', 'instructions': 'Punctuate.'})
                with patch('app.normalize_audio', return_value=(b'audio', 2.0)):
                    response = client.post('/api/transcribe', headers={**HEADERS, 'X-Voicepad-Profile': '1'}, content=b'audio')
                return response

    def test_deep_provider_json_keeps_raw_transcript(self):
        # Valid JSON within the documented byte limit; Python's parser rejects depth.
        body = 'data: ' + '{"nested":' * 1500 + 'null' + '}' * 1500 + '\n\n'
        response = self.request(httpx.Response(200, text=body))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['text'], 'RAW_TRANSCRIPT_MUST_SURVIVE')
        self.assertFalse(response.json()['formatted'])

    def test_formatter_refresh_disk_failure_keeps_raw_transcript(self):
        response = self.request(httpx.Response(401), OSError('disk full during grant persistence'))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['text'], 'RAW_TRANSCRIPT_MUST_SURVIVE')
        self.assertFalse(response.json()['formatted'])

    def test_nine_valid_unicode_profiles_remain_readable_after_restart(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            with TestClient(create_app(state_dir=directory)) as client:
                for slot in range(1, 10):
                    # Browser JSON.stringify sends UTF-8, not ASCII Unicode escapes.
                    body = json.dumps({'name': 'Hindi', 'instructions': '\u0905' * 4000}, ensure_ascii=False).encode()
                    response = client.put(f'/api/profiles/{slot}', headers=HEADERS, content=body)
                    self.assertEqual(response.status_code, 200, response.text)
            with TestClient(create_app(state_dir=directory)) as client:
                response = client.get('/api/profiles')
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(len(response.json()['profiles']), 9)

    def test_stream_limit_applies_before_newline(self):
        from formatter import FormattingError, format_text
        from formatting_metrics import FormattingMetrics
        class LongLine(httpx.AsyncByteStream):
            consumed = 0
            async def __aiter__(self):
                for _ in range(64):
                    self.consumed += 65536
                    yield b'x' * 65536
                yield b'\n'
        class Auth:
            async def credentials(self, **kwargs):
                return {'access_token': 'test', 'account_id': 'test'}
        stream = LongLine()
        async def run():
            with tempfile.TemporaryDirectory() as directory:
                transport = httpx.MockTransport(lambda request: httpx.Response(200, stream=stream))
                with self.assertRaises(FormattingError):
                    await format_text('raw', 'format', Auth(), FormattingMetrics(Path(directory) / 'metrics.json'), transport)
        asyncio.run(run())
        self.assertLessEqual(stream.consumed, 1_000_000 + 65536,
                             'line decoder consumed entire oversized line before the size check')

    def test_profile_is_snapshotted_before_upload_and_transcripts_are_not_persisted(self):
        from app import create_app
        calls = []
        async def run():
            with tempfile.TemporaryDirectory() as directory:
                def upstream(request):
                    if request.url.path.endswith('/transcribe'):
                        return httpx.Response(200, json={'text': 'PRIVATE_RAW_MARKER'})
                    calls.append(json.loads(request.content))
                    events = [{'type': 'response.output_text.delta', 'delta': 'PRIVATE_FORMATTED_MARKER'},
                              {'type': 'response.completed', 'response': {'usage': None}}]
                    return httpx.Response(200, text=''.join('data: ' + json.dumps(e) + '\n\n' for e in events))
                app = create_app(state_dir=directory, transport=httpx.MockTransport(upstream))
                connect_test_grant(app)
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://testserver') as client:
                    await client.put('/api/profiles/1', headers=HEADERS, json={'name': 'Before', 'instructions': 'BEFORE_INSTRUCTIONS'})
                    async def upload():
                        await client.put('/api/profiles/1', headers=HEADERS, json={'name': 'After', 'instructions': 'AFTER_INSTRUCTIONS'})
                        yield b'audio'
                    with patch('app.normalize_audio', return_value=(b'audio', 2.0)):
                        response = await client.post('/api/transcribe', headers={**HEADERS, 'X-Voicepad-Profile': '1'}, content=upload())
                    self.assertEqual(response.status_code, 200, response.text)
                    self.assertEqual(response.json()['profile']['name'], 'Before')
                    self.assertEqual(calls[0]['input'][0]['content'][0]['text'], 'BEFORE_INSTRUCTIONS')
                    for file in Path(directory).iterdir():
                        content = file.read_bytes()
                        self.assertNotIn(b'PRIVATE_RAW_MARKER', content)
                        self.assertNotIn(b'PRIVATE_FORMATTED_MARKER', content)
        asyncio.run(run())
