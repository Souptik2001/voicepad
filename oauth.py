"""Independent Codex device OAuth. No Hermes/CLI credential import or shared refresh grant."""
import asyncio
import base64
import json
import os
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

ISSUER = 'https://auth.openai.com'
CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann'


def iso(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat() if timestamp else None


def claims(token):
    return json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '==='))


class AuthFailure(Exception):
    def __init__(self, message, code='auth_failed', status=502):
        super().__init__(message)
        self.code, self.status = code, status


class CodexAuth:
    def __init__(self, directory, transport=None):
        self.directory = Path(directory)
        self.path = self.directory / 'oauth.json'
        self.transport = transport
        self.grant = None
        self.last_error = None
        self.reconnect = False
        self.retry_at = 0
        self.login = {'state': 'idle'}
        self.pending = None
        self.login_generation = 0
        self.login_task = None
        self.worker = None
        self.lock = asyncio.Lock()
        if self.path.exists():
            try:
                saved = json.loads(self.path.read_text())
                if saved.get('access_token') and saved.get('refresh_token') and saved.get('account_id'):
                    self.grant = saved
                    self.reconnect = bool(saved.get('reconnect_required'))
                    if self.reconnect:
                        self.last_error = 'OpenAI sign-in needs reconnecting. Connect Codex again.'
            except (OSError, ValueError, TypeError):
                self.last_error = 'Saved sign-in could not be read. Connect Codex again.'

    def status(self):
        connected = bool(self.grant and not self.reconnect)
        return {'connected': connected,
                'auth_state': 'reconnect_required' if self.reconnect else 'connected' if connected else 'disconnected',
                'credential_expires_at': iso(self.grant.get('expires_at')) if self.grant else None,
                'auto_refresh': True,
                'last_refresh_at': self.grant.get('last_refresh_at') if self.grant else None,
                'last_error': self.last_error, 'refresh_retry_at': iso(self.retry_at),
                'login': dict(self.login)}

    def persist(self, payload, previous=None):
        access = payload.get('access_token')
        refresh = payload.get('refresh_token') or (previous or {}).get('refresh_token')
        if not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh:
            raise AuthFailure('OpenAI did not return a complete sign-in. Connect Codex again.')
        try:
            decoded = claims(access)
            account = decoded.get('https://api.openai.com/auth', {}).get('chatgpt_account_id')
            if not account and payload.get('id_token'):
                account = claims(payload['id_token']).get('https://api.openai.com/auth', {}).get('chatgpt_account_id')
            account = account or (previous or {}).get('account_id')
            expiry = float(decoded.get('exp') or time.time() + float(payload.get('expires_in', 3600)))
            if not account or expiry <= time.time():
                raise ValueError('Missing account or expired token')
        except (ValueError, IndexError, TypeError, KeyError):
            raise AuthFailure('OpenAI returned an invalid sign-in response.') from None
        grant = {'access_token': access, 'refresh_token': refresh, 'account_id': account,
                 'expires_at': expiry, 'last_refresh_at': iso(time.time())}
        self.write_grant(grant)
        self.grant, self.last_error, self.reconnect, self.retry_at = grant, None, False, 0

    def write_grant(self, grant):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        descriptor, name = tempfile.mkstemp(prefix='.oauth-', dir=self.directory)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, 'w') as output:
                json.dump(grant, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def mark_reconnect(self):
        self.reconnect = True
        if self.grant:
            self.grant['reconnect_required'] = True
            self.write_grant(self.grant)

    async def request(self, path, **kwargs):
        try:
            async with httpx.AsyncClient(transport=self.transport, timeout=20, follow_redirects=False) as client:
                return await client.post(ISSUER + path, headers={'Accept': 'application/json', 'User-Agent': 'voicepad-poc/0.2'}, **kwargs)
        except httpx.HTTPError:
            raise AuthFailure('Could not reach OpenAI authentication. Try again shortly.', 'auth_network') from None

    async def begin_login(self, background=True):
        await self.cancel_login()
        generation = self.login_generation
        async with self.lock:
            if generation != self.login_generation:
                return dict(self.login)
            response = await self.request('/api/accounts/deviceauth/usercode', json={'client_id': CLIENT_ID})
            if generation != self.login_generation:
                return dict(self.login)
            if response.status_code != 200:
                raise AuthFailure('OpenAI could not start device sign-in. Device login may need enabling in your ChatGPT security settings.', 'device_login_unavailable')
            try:
                data = response.json()
                pending = {'device_auth_id': data['device_auth_id'], 'user_code': data.get('user_code') or data['usercode'],
                           'interval': max(5, int(data.get('interval', 5))), 'expires_at': time.time() + 900}
                if not pending['device_auth_id'] or not pending['user_code']:
                    raise ValueError('Empty code')
            except (ValueError, KeyError, TypeError):
                raise AuthFailure('OpenAI returned an invalid device sign-in response.') from None
            self.pending = pending
            self.login = {'state': 'pending', 'verification_url': ISSUER + '/codex/device',
                          'user_code': pending['user_code'], 'expires_at': iso(pending['expires_at'])}
            if background:
                self.login_task = asyncio.create_task(self.poll_loop())
            return dict(self.login)

    async def poll_once(self):
        pending = self.pending
        if not pending:
            return
        if time.time() >= pending['expires_at']:
            self.pending = None
            self.login = {'state': 'expired', 'error': 'Sign-in expired. Start a new login.'}
            return
        response = await self.request('/api/accounts/deviceauth/token', json={
            'device_auth_id': pending['device_auth_id'], 'user_code': pending['user_code']})
        if self.pending is not pending:
            return
        if response.status_code in (403, 404):
            return
        if response.status_code == 429:
            pending['interval'] = min(60, pending['interval'] + 5)
            return
        if response.status_code != 200:
            raise AuthFailure('OpenAI device sign-in failed. Start a new login.')
        try:
            data = response.json()
            code, verifier = data['authorization_code'], data['code_verifier']
        except (ValueError, KeyError, TypeError):
            raise AuthFailure('OpenAI returned an invalid authorization response.') from None
        async with self.lock:
            if self.pending is not pending:
                return
            tokens = await self.request('/oauth/token', data={
                'grant_type': 'authorization_code', 'client_id': CLIENT_ID,
                'code': code, 'code_verifier': verifier, 'redirect_uri': ISSUER + '/deviceauth/callback'})
            if self.pending is not pending:
                return
            if tokens.status_code != 200:
                raise AuthFailure('OpenAI could not complete sign-in. Start a new login.')
            try:
                self.persist(tokens.json())
            except ValueError:
                raise AuthFailure('OpenAI returned an invalid token response.') from None
            self.pending = None
            self.login = {'state': 'connected'}

    async def poll_loop(self):
        try:
            while self.pending:
                await asyncio.sleep(self.pending['interval'])
                await self.poll_once()
        except AuthFailure as exc:
            self.pending = None
            self.login = {'state': 'error', 'error': str(exc)}

    async def cancel_login(self):
        self.login_generation += 1
        self.pending = None
        self.login = {'state': 'idle'}
        task, self.login_task = self.login_task, None
        if task and task is not asyncio.current_task():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    async def reject_credentials(self, observed):
        async with self.lock:
            if self.grant and self.grant['access_token'] == observed:
                self.mark_reconnect()

    async def credentials(self, force=False, observed=None):
        async with self.lock:
            if not self.grant or self.reconnect:
                raise AuthFailure('Connect your Codex account in Administration.', 'not_connected', 503)
            # A second 401 caller adopts the token already rotated by the first.
            if observed and self.grant['access_token'] != observed:
                return dict(self.grant)
            if not force and self.grant['expires_at'] > time.time() + 300:
                return dict(self.grant)
            if self.retry_at > time.time():
                raise AuthFailure('OpenAI authentication is cooling down. Try again shortly.', 'refresh_cooldown', 503)
            try:
                response = await self.request('/oauth/token', data={
                    'grant_type': 'refresh_token', 'client_id': CLIENT_ID,
                    'refresh_token': self.grant['refresh_token']})
                if response.status_code in (400, 401, 403):
                    self.mark_reconnect()
                    raise AuthFailure('OpenAI sign-in needs reconnecting. Connect Codex again.', 'reconnect_required', 503)
                if response.status_code != 200:
                    raise AuthFailure('OpenAI could not refresh sign-in. It will retry shortly.', 'refresh_unavailable', 503)
                try:
                    payload = response.json()
                except ValueError:
                    raise AuthFailure('OpenAI returned an invalid refresh response.', 'refresh_unavailable', 503) from None
                self.persist(payload, previous=self.grant)
            except AuthFailure as exc:
                self.last_error = str(exc)
                self.retry_at = time.time() + 60
                raise
            return dict(self.grant)

    async def refresh_loop(self):
        while True:
            await asyncio.sleep(30)
            if self.grant and not self.reconnect:
                try:
                    await self.credentials()
                except AuthFailure:
                    pass

    async def disconnect(self):
        await self.cancel_login()
        async with self.lock:
            self.grant = None
            self.reconnect = False
            self.last_error = None
            self.retry_at = 0
            self.path.unlink(missing_ok=True)

    async def close(self):
        await self.cancel_login()
        if self.worker:
            self.worker.cancel()
            try:
                await self.worker
            except asyncio.CancelledError:
                pass
