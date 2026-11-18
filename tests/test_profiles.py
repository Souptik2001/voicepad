import json
import tempfile
import unittest
from pathlib import Path
from fastapi.testclient import TestClient

H={'X-Requested-With':'voicepad'}

class ProfileTests(unittest.TestCase):
    def test_nine_fixed_slots_persist_and_empty_instructions_are_allowed(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            with TestClient(create_app(state_dir=directory)) as c:
                self.assertEqual(c.get('/api/profiles').json(), {'profiles':[]})
                for slot in range(1,10):
                    r=c.put(f'/api/profiles/{slot}',headers=H,json={'name':f' Profile {slot} ','instructions':''})
                    self.assertEqual(r.status_code,200,r.text)
                self.assertEqual(len(r.json()['profiles']),9)
                self.assertEqual(r.json()['profiles'][0],{'slot':1,'name':'Profile 1','instructions':''})
                self.assertEqual(c.put('/api/profiles/10',headers=H,json={'name':'No','instructions':''}).status_code,422)
                self.assertEqual(c.delete('/api/profiles/3',headers=H).status_code,200)
            with TestClient(create_app(state_dir=directory)) as c:
                self.assertEqual([p['slot'] for p in c.get('/api/profiles').json()['profiles']],[1,2,4,5,6,7,8,9])
            self.assertEqual((Path(directory)/'profiles.json').stat().st_mode&0o777,0o600)

    def test_validation_and_cross_origin_protection(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory, TestClient(create_app(state_dir=directory)) as c:
            body={'name':'Official','instructions':'Be professional.'}
            self.assertEqual(c.put('/api/profiles/1',json=body).status_code,403)
            self.assertEqual(c.put('/api/profiles/1',headers={**H,'Origin':'https://evil.example'},json=body).status_code,403)
            for body in [{'name':'','instructions':''},{'name':'x'*61,'instructions':''},{'name':'a','instructions':'x'*4001},{'name':3,'instructions':''},{'name':'x','instructions':None},{'name':'x','instructions':'','extra':'no'}]:
                self.assertEqual(c.put('/api/profiles/1',headers=H,json=body).status_code,422)
            self.assertEqual(c.put('/api/profiles/1',headers=H,content=b'x'*20000).status_code,413)
            self.assertEqual(c.delete('/api/profiles/1').status_code,403)

    def test_corrupt_storage_never_overwritten_and_write_failure_is_visible(self):
        from app import create_app
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'profiles.json';path.write_text('broken')
            with TestClient(create_app(state_dir=directory)) as c:
                self.assertEqual(c.get('/api/profiles').status_code,503)
                self.assertEqual(c.put('/api/profiles/1',headers=H,json={'name':'A','instructions':''}).status_code,503)
                self.assertEqual(path.read_text(),'broken')
        with tempfile.TemporaryDirectory() as directory, TestClient(create_app(state_dir=directory)) as c:
            with patch('profiles.os.replace',side_effect=OSError('full')):
                self.assertEqual(c.put('/api/profiles/1',headers=H,json={'name':'A','instructions':''}).status_code,503)
            self.assertEqual(c.get('/api/profiles').json(),{'profiles':[]})
