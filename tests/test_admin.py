import tempfile
import unittest
from pathlib import Path
from fastapi.testclient import TestClient
import httpx


class AdminTests(unittest.TestCase):
    def test_tailnet_mode_has_no_key_gate_and_admin_requires_same_origin_mutation(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            app = create_app(state_dir=Path(directory), public_origin='https://private.example', transport=httpx.MockTransport(lambda r: httpx.Response(500)))
            with TestClient(app) as client:
                result = client.get('/api/status', headers={'Host':'private.example'})
                self.assertEqual(result.status_code, 200)
                self.assertFalse(result.json()['credential_available'])
                self.assertEqual(client.get('/api/admin/status').status_code, 200)
                for route in ['login','cancel','disconnect','refresh']:
                    self.assertEqual(client.post('/api/admin/' + route).status_code, 403)
                    self.assertEqual(client.post('/api/admin/' + route, headers={'X-Requested-With':'voicepad','Origin':'https://evil.example'}).status_code, 403)
                good = {'X-Requested-With':'voicepad','Origin':'https://private.example','Host':'private.example'}
                self.assertEqual(client.post('/api/admin/disconnect', headers=good).status_code, 200)
                self.assertFalse(app.state.auth.path.exists())

    def test_foreign_host_is_rejected_to_prevent_dns_rebinding(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            with TestClient(create_app(state_dir=directory, public_origin='https://private.example')) as client:
                self.assertEqual(client.get('/api/admin/status', headers={'Host':'attacker.example'}).status_code, 400)
                self.assertEqual(client.get('/api/admin/status', headers={'Host':'private.example'}).status_code, 200)

    def test_admin_login_real_contract_and_sanitized_status(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            calls=[]
            def upstream(request):
                calls.append(request)
                return httpx.Response(200,json={'device_auth_id':'hidden-device-id','user_code':'ABCD-EFGH','interval':'5'})
            app=create_app(state_dir=Path(directory),transport=httpx.MockTransport(upstream))
            with TestClient(app) as client:
                response=client.post('/api/admin/login',headers={'X-Requested-With':'voicepad'})
                self.assertEqual(response.status_code,200)
                self.assertEqual(response.json()['user_code'],'ABCD-EFGH')
                self.assertNotIn('hidden-device-id',response.text)
                self.assertEqual(client.get('/api/admin/status').json()['login']['state'],'pending')
                self.assertEqual(client.post('/api/admin/cancel',headers={'X-Requested-With':'voicepad'}).status_code,200)
                self.assertEqual(client.get('/api/admin/status').json()['login']['state'],'idle')
            self.assertEqual(len(calls),1)
