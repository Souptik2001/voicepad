import asyncio
import base64
import json
import tempfile
import time
import unittest
from pathlib import Path

import httpx


def jwt(exp=None, account='test-account'):
    claims = {'exp': exp or time.time() + 3600, 'https://api.openai.com/auth': {'chatgpt_account_id': account}}
    return 'header.' + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=') + '.signature'


class OAuthTests(unittest.IsolatedAsyncioTestCase):
    async def test_device_login_stores_own_grant_without_exposing_tokens(self):
        from oauth import CodexAuth
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def upstream(request):
                calls.append(request)
                if request.url.path.endswith('/usercode'):
                    return httpx.Response(200, json={'device_auth_id': 'private-device-id', 'user_code': 'ABCD-EFGH', 'interval': '5'})
                if request.url.path.endswith('/deviceauth/token'):
                    return httpx.Response(200, json={'authorization_code': 'authorization-secret', 'code_verifier': 'verifier-secret'})
                if request.url.path == '/oauth/token':
                    self.assertIn(b'grant_type=authorization_code', request.content)
                    self.assertIn(b'redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback', request.content)
                    return httpx.Response(200, json={'access_token': jwt(), 'refresh_token': 'own-refresh-secret'})
                self.fail(str(request.url))
            manager = CodexAuth(Path(directory), transport=httpx.MockTransport(upstream))
            login = await manager.begin_login(background=False)
            self.assertEqual(login['verification_url'], 'https://auth.openai.com/codex/device')
            self.assertEqual(login['user_code'], 'ABCD-EFGH')
            await manager.poll_once()
            public = manager.status()
            self.assertTrue(public['connected'])
            self.assertTrue(public['auto_refresh'])
            for secret in ['own-refresh-secret', 'authorization-secret', 'verifier-secret', 'private-device-id', 'test-account']:
                self.assertNotIn(secret, json.dumps(public))
            store = Path(directory) / 'oauth.json'
            stored = json.loads(store.read_text())
            self.assertEqual(stored['refresh_token'], 'own-refresh-secret')
            self.assertEqual(store.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(calls), 3)
            await manager.close()

    async def test_concurrent_refresh_rotates_once_and_survives_reload(self):
        from oauth import CodexAuth
        with tempfile.TemporaryDirectory() as directory:
            count = 0
            async def upstream(request):
                nonlocal count
                count += 1
                await asyncio.sleep(0.01)
                self.assertIn(b'refresh_token=original-refresh', request.content)
                return httpx.Response(200, json={'access_token': jwt(time.time() + 7200), 'refresh_token': 'rotated-refresh'})
            manager = CodexAuth(Path(directory), transport=httpx.MockTransport(upstream))
            manager.persist({'access_token': jwt(time.time() + 60), 'refresh_token': 'original-refresh'})
            results = await asyncio.gather(*(manager.credentials() for _ in range(5)))
            self.assertEqual(count, 1)
            self.assertTrue(all(result['refresh_token'] == 'rotated-refresh' for result in results))
            reloaded = CodexAuth(Path(directory))
            self.assertEqual(reloaded.grant['refresh_token'], 'rotated-refresh')
            self.assertIsNone(reloaded.status()['last_error'])
            await manager.close()

    async def test_rejected_refresh_requires_reconnect_and_never_leaks_provider_error(self):
        from oauth import CodexAuth, AuthFailure
        with tempfile.TemporaryDirectory() as directory:
            def upstream(request):
                return httpx.Response(400, json={'error': 'refresh_token_reused SECRET'})
            manager = CodexAuth(Path(directory), transport=httpx.MockTransport(upstream))
            manager.persist({'access_token': jwt(time.time() + 60), 'refresh_token': 'refresh-secret'})
            with self.assertRaises(AuthFailure):
                await manager.credentials()
            self.assertEqual(manager.status()['auth_state'], 'reconnect_required')
            self.assertNotIn('SECRET', json.dumps(manager.status()))
            self.assertTrue(manager.path.exists())
            await manager.disconnect()
            self.assertFalse(manager.path.exists())
            self.assertFalse(manager.status()['connected'])

    async def test_cancel_and_disconnect_invalidate_delayed_login_initiation(self):
        from oauth import CodexAuth
        for operation in ['cancel_login', 'disconnect']:
            with tempfile.TemporaryDirectory() as directory:
                started, release = asyncio.Event(), asyncio.Event()
                async def upstream(request):
                    started.set()
                    await release.wait()
                    return httpx.Response(200,json={'device_auth_id':'private','user_code':'CODE','interval':'5'})
                manager=CodexAuth(Path(directory),transport=httpx.MockTransport(upstream))
                login=asyncio.create_task(manager.begin_login(background=False))
                await started.wait()
                cancellation=asyncio.create_task(getattr(manager,operation)())
                await asyncio.sleep(0)
                release.set()
                await asyncio.gather(login,cancellation)
                self.assertIsNone(manager.pending)
                self.assertEqual(manager.status()['login']['state'],'idle')
                self.assertFalse(manager.path.exists())

    async def test_stale_provider_rejection_cannot_disable_replacement_login(self):
        from oauth import CodexAuth
        with tempfile.TemporaryDirectory() as directory:
            manager=CodexAuth(Path(directory))
            manager.persist({'access_token':jwt(account='old'),'refresh_token':'old-refresh'})
            old=manager.grant['access_token']
            manager.persist({'access_token':jwt(account='new'),'refresh_token':'new-refresh'})
            await manager.reject_credentials(old)
            self.assertTrue(manager.status()['connected'])
            self.assertFalse(manager.grant.get('reconnect_required',False))

    async def test_missing_rotated_refresh_retains_existing_refresh_token(self):
        from oauth import CodexAuth
        with tempfile.TemporaryDirectory() as directory:
            manager = CodexAuth(Path(directory), transport=httpx.MockTransport(lambda r: httpx.Response(200,json={'access_token':jwt()})))
            manager.persist({'access_token':jwt(time.time()+60),'refresh_token':'keep-original'})
            result = await manager.credentials()
            self.assertEqual(result['refresh_token'],'keep-original')
            self.assertEqual(json.loads(manager.path.read_text())['refresh_token'],'keep-original')

    async def test_reconnect_required_survives_restart_without_reusing_rejected_token(self):
        from oauth import CodexAuth, AuthFailure
        with tempfile.TemporaryDirectory() as directory:
            manager = CodexAuth(Path(directory), transport=httpx.MockTransport(lambda r: httpx.Response(400)))
            manager.persist({'access_token': jwt(time.time() + 60), 'refresh_token':'rejected'})
            with self.assertRaises(AuthFailure):
                await manager.credentials()
            reloaded = CodexAuth(Path(directory))
            self.assertEqual(reloaded.status()['auth_state'], 'reconnect_required')
            self.assertFalse(reloaded.status()['connected'])

    async def test_transient_refresh_preserves_rotating_grant_and_cools_down(self):
        from oauth import CodexAuth, AuthFailure
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def upstream(request):
                calls.append(request)
                return httpx.Response(429, json={'error': 'limited'})
            manager = CodexAuth(Path(directory), transport=httpx.MockTransport(upstream))
            manager.persist({'access_token': jwt(time.time() + 60), 'refresh_token': 'preserved'})
            for _ in range(2):
                with self.assertRaises(AuthFailure):
                    await manager.credentials()
            self.assertEqual(len(calls), 1)
            self.assertEqual(manager.grant['refresh_token'], 'preserved')
            self.assertFalse(manager.reconnect)

    async def test_pending_expired_cancelled_signin_and_independent_empty_store(self):
        from oauth import CodexAuth
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def upstream(request):
                calls.append(request)
                if request.url.path.endswith('/usercode'):
                    return httpx.Response(200, json={'device_auth_id':'private', 'user_code':'USER-CODE', 'interval':'5'})
                return httpx.Response(403)
            manager = CodexAuth(Path(directory), transport=httpx.MockTransport(upstream))
            self.assertFalse(manager.status()['connected'])
            await manager.begin_login(background=False)
            await manager.poll_once()
            self.assertEqual(manager.status()['login']['state'], 'pending')
            manager.pending['expires_at'] = time.time() - 1
            await manager.poll_once()
            self.assertEqual(manager.status()['login']['state'], 'expired')
            await manager.begin_login(background=False)
            await manager.cancel_login()
            await manager.poll_once()
            self.assertEqual(manager.status()['login']['state'], 'idle')
            self.assertFalse(manager.path.exists())

if __name__ == '__main__':
    unittest.main()
