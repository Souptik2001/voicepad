"""Private experimental Codex dictation POC; no paid API fallback or history."""
import asyncio
import base64
import hmac
import io
import json
import os
import subprocess
import tempfile
import time
import uuid
import wave
from datetime import datetime, timezone
from pathlib import Path

import httpx
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse, FileResponse
from starlette.concurrency import run_in_threadpool

ROOT = Path(__file__).parent
MAX_BYTES = 25 * 1024 * 1024
MAX_SECONDS = 600
ALLOWED_TYPES = {'audio/webm', 'audio/mp4', 'audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/ogg', 'audio/aac', 'video/mp4'}


def error(message, code, status):
    return JSONResponse({'error': message, 'code': code}, status_code=status)


def normalize_audio(body):
    # Local input only; external media protocols and playlists are not accepted.
    with tempfile.TemporaryDirectory(prefix='voicepad-') as directory:
        source, output = Path(directory) / 'input', Path(directory) / 'audio.wav'
        source.write_bytes(body)
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                        '-max_alloc', '67108864', '-protocol_whitelist', 'file,pipe',
                        '-format_whitelist', 'wav,matroska,webm,mov,mp3,ogg,aac,flac',
                        '-i', str(source), '-vn', '-ac', '1', '-ar', '16000',
                        '-t', str(MAX_SECONDS + 1), '-c:a', 'pcm_s16le', '-y', str(output)],
                       timeout=60, check=True, capture_output=True)
        audio = output.read_bytes()
        with wave.open(io.BytesIO(audio)) as reader:
            duration = reader.getnframes() / reader.getframerate()
        return audio, duration


def create_app(state_dir=None, transport=None, auth_transport=None, public_origin=None):
    from contextlib import asynccontextmanager
    from oauth import CodexAuth, AuthFailure
    from metrics import UsageMetrics
    from profiles import Profiles, ProfileError, validate_profile
    state_root = Path(state_dir or os.environ.get('VOICEPAD_STATE_DIR', '/data'))
    auth = CodexAuth(state_root, transport=auth_transport or transport)
    metrics = UsageMetrics(state_root / 'metrics.json')
    profiles = Profiles(state_root / 'profiles.json')
    from formatter import format_text, FormattingError
    from formatting_metrics import FormattingMetrics
    formatting_metrics = FormattingMetrics(state_root / 'formatting-metrics.json')
    public_origin = public_origin or os.environ.get('VOICEPAD_PUBLIC_ORIGIN', 'http://localhost:8791')
    from urllib.parse import urlsplit
    origin = urlsplit(public_origin)
    if (origin.scheme not in ('http','https') or not origin.hostname or origin.path or origin.query
            or origin.fragment or origin.username is not None or origin.password is not None
            or any(char.isspace() for char in public_origin) or '*' in public_origin
            or (origin.scheme == 'http' and origin.hostname not in ('localhost','127.0.0.1','::1'))):
        raise ValueError('VOICEPAD_PUBLIC_ORIGIN must be an exact HTTPS origin without a path, or HTTP loopback.')
    try:
        origin.port
    except ValueError:
        raise ValueError('VOICEPAD_PUBLIC_ORIGIN contains an invalid port.') from None

    @asynccontextmanager
    async def lifespan(app):
        auth.worker = asyncio.create_task(auth.refresh_loop())
        yield
        await auth.close()

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    from urllib.parse import urlsplit
    from starlette.middleware.trustedhost import TrustedHostMiddleware
    allowed_hosts = [urlsplit(public_origin).hostname, '127.0.0.1', 'localhost', 'testserver']
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=[host for host in allowed_hosts if host])
    app.state.auth = auth
    app.state.busy = False
    app.state.requests = []
    app.state.last_login = 0

    @app.exception_handler(AuthFailure)
    async def auth_error(request, exc):
        return error(str(exc), exc.code, exc.status)

    @app.middleware('http')
    async def security(request: Request, call_next):
        response = None
        # Tailnet is the access boundary; retain CSRF protection without a key gate.
        origin = request.headers.get('origin')
        if origin and origin != public_origin:
            response = error('Cross-origin access is not permitted.', 'invalid_origin', 403)
        if request.headers.get('sec-fetch-site') == 'cross-site':
            response = error('Cross-site access is not permitted.', 'invalid_origin', 403)
        if request.url.path.startswith('/api/') and request.method not in ('GET', 'HEAD'):
            if request.headers.get('x-requested-with') != 'voicepad':
                response = error('Invalid request origin.', 'invalid_request', 403)
        if response is None:
            response = await call_next(request)
        response.headers.update({'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
                                 'Referrer-Policy': 'no-referrer',
                                 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
                                 'Permissions-Policy': 'microphone=(self), camera=(), geolocation=()'})
        return response

    @app.get('/healthz')
    async def health():
        return {'ok': True}

    @app.get('/api/status')
    async def status():
        public = auth.status()
        return {'provider': 'codex-subscription', 'experimental': True, 'max_seconds': MAX_SECONDS, 'max_bytes': MAX_BYTES,
                'audio_retention': 'Provider response reported 30-day asset lifetime.',
                'quota': 'Not reported by provider', 'credential_expires_at': public['credential_expires_at'],
                'credential_available': public['connected'], 'auth_state': public['auth_state'], 'auto_refresh': True}

    @app.exception_handler(ProfileError)
    async def profile_error(request, exc):
        return JSONResponse({'code':'profiles_unavailable','error':str(exc)},status_code=503)

    @app.get('/api/profiles')
    async def list_profiles():
        return profiles.snapshot()

    @app.put('/api/profiles/{slot}')
    async def save_profile(slot: int, request: Request):
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > 18000:
                raise HTTPException(413, detail={'code':'profile_size','message':'Profile payload is too large.'})
        try:
            data = json.loads(body)
            if not isinstance(data,dict) or set(data) != {'name','instructions'}:
                raise ValueError('Provide name and instructions only.')
            validate_profile(slot, **data)
        except (ValueError,TypeError) as exc:
            raise HTTPException(422, detail={'code':'invalid_profile','message':str(exc)}) from None
        return profiles.save(slot,data)

    @app.delete('/api/profiles/{slot}')
    async def delete_profile(slot: int):
        if not 1 <= slot <= 9:
            raise HTTPException(422, detail={'code':'invalid_profile','message':'Choose a profile slot from 1 to 9.'})
        return profiles.save(slot)

    @app.get('/api/metrics')
    async def usage_metrics():
        return {**metrics.snapshot(), 'formatting':formatting_metrics.snapshot()}

    @app.get('/api/admin/status')
    async def admin_status():
        return auth.status()

    @app.post('/api/admin/login')
    async def login():
        now = time.monotonic()
        if now - app.state.last_login < 5:
            return error('Please wait a few seconds before starting another login.', 'login_rate_limit', 429)
        app.state.last_login = now
        return await auth.begin_login()

    @app.post('/api/admin/cancel')
    async def cancel_login():
        await auth.cancel_login()
        return auth.status()

    @app.post('/api/admin/disconnect')
    async def disconnect():
        await auth.disconnect()
        return auth.status()

    @app.post('/api/admin/refresh')
    async def refresh():
        await auth.credentials(force=True)
        return auth.status()

    @app.post('/api/transcribe')
    async def transcribe(request: Request):
        if request.headers.get('x-requested-with') != 'voicepad':
            return error('Invalid request origin.', 'invalid_request', 403)
        if request.headers.get('content-type', '').split(';')[0].lower() not in ALLOWED_TYPES:
            return error('Use a supported audio recording.', 'unsupported_audio', 415)
        try:
            length = int(request.headers.get('content-length', '0'))
        except ValueError:
            return error('Invalid upload size.', 'invalid_upload', 400)
        if length > MAX_BYTES:
            return error('Recording exceeds the 25 MB limit.', 'too_large', 413)
        profile = None
        slot = request.headers.get('x-voicepad-profile')
        if slot is not None:
            if len(slot) != 1 or slot not in '123456789':
                return error('Choose a profile slot from 1 to 9.', 'invalid_profile', 422)
            profile = profiles.get(int(slot))
            if profile is None:
                return error('Selected profile no longer exists. Refresh profiles and retry.', 'invalid_profile', 422)
        if app.state.busy:
            return error('Another transcription is running. Try again shortly.', 'busy', 429)
        now = time.monotonic()
        app.state.requests = [t for t in app.state.requests if now - t < 60]
        if len(app.state.requests) >= 10:
            return error('Please wait before another test.', 'rate_limit', 429)
        app.state.busy = True
        duration = 0.0
        successful = False
        try:
            body = bytearray()
            async with asyncio.timeout(60):
                async for chunk in request.stream():
                    body.extend(chunk)
                    if len(body) > MAX_BYTES:
                        return error('Recording exceeds the 25 MB limit.', 'too_large', 413)
            if not body:
                return error('Recording was empty.', 'empty_audio', 400)
            try:
                audio, duration = await run_in_threadpool(normalize_audio, bytes(body))
            except (subprocess.SubprocessError, wave.Error, OSError, ValueError):
                return error('The recording could not be decoded as audio.', 'invalid_audio', 422)
            if not 1 <= duration <= MAX_SECONDS:
                return error('Record between 1 and 600 seconds (10 minutes).', 'duration_limit', 422)
            credentials = await auth.credentials()
            app.state.requests.append(time.monotonic())
            async def send(credentials):
                headers = {'Authorization': 'Bearer ' + credentials['access_token'],
                           'ChatGPT-Account-Id': credentials['account_id'], 'User-Agent': 'voicepad-poc/0.2'}
                async with httpx.AsyncClient(transport=transport, timeout=httpx.Timeout(120, connect=10), follow_redirects=False) as client:
                    metrics.attempt(duration)
                    async with asyncio.timeout(125):
                        return await client.post('https://chatgpt.com/backend-api/transcribe', headers=headers,
                                             files={'file': ('audio.wav', audio, 'audio/wav')})
            response = await send(credentials)
            if response.status_code == 401:
                credentials = await auth.credentials(force=True, observed=credentials['access_token'])
                response = await send(credentials)
                if response.status_code == 401:
                    await auth.reject_credentials(credentials['access_token'])
                    return error('OpenAI rejected the renewed login. Connect Codex again.', 'reconnect_required', 503)
            if response.status_code == 429:
                return error('OpenAI limited this request. No paid fallback was used.', 'provider_rate_limit', 429)
            if response.status_code == 403:
                return error('OpenAI blocked this experimental dictation request. No paid fallback was used.', 'provider_blocked', 502)
            response.raise_for_status()
            data = response.json()
            if not isinstance(data.get('text'), str):
                raise ValueError('Missing transcript')
            text = data['text']
            formatted = False
            warning = None
            formatting_usage = None
            if profile and profile['instructions'].strip() and text.strip():
                try:
                    text, formatting_usage = await format_text(text, profile['instructions'], auth, formatting_metrics, transport)
                    formatted = True
                except FormattingError as exc:
                    warning = str(exc)
            successful = True
            return {'text': text, 'elapsed_seconds': round(time.monotonic() - now, 3),
                    'audio_seconds': round(duration, 3), 'provider': 'codex-subscription', 'usage': None,
                    'formatted': formatted, 'warning': warning, 'formatting_usage': formatting_usage,
                    'profile': {'slot':profile['slot'],'name':profile['name']} if profile else None,
                    'provider_audio_retention': data.get('asset_ttl'), 'request_id': uuid.uuid4().hex}
        except (httpx.HTTPError, ValueError):
            return error('Transcription failed. No paid fallback was used.', 'transcription_failed', 502)
        except TimeoutError:
            return error('The upload timed out. Please retry.', 'upload_timeout', 408)
        finally:
            app.state.busy = False
            metrics.finish(success=successful, audio_seconds=duration, elapsed=time.monotonic() - now)

    @app.get('/')
    async def index():
        return FileResponse(ROOT / 'static' / 'index.html')

    @app.get('/admin')
    async def admin_page():
        return FileResponse(ROOT / 'static' / 'admin.html')

    @app.get('/profiles')
    async def profiles_page():
        return FileResponse(ROOT / 'static' / 'profiles.html')

    @app.get('/usage')
    async def usage_page():
        return FileResponse(ROOT / 'static' / 'usage.html')

    @app.get('/{filename}')
    async def static(filename: str):
        if filename not in {'app.mjs', 'core.mjs', 'admin.mjs', 'usage.mjs', 'profiles.mjs', 'styles.css', 'favicon.svg'}:
            return error('Not found.', 'not_found', 404)
        return FileResponse(ROOT / 'static' / filename)

    return app


app = create_app()
