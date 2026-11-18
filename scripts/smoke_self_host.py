"""Exercise fresh-checkout setup and Compose without touching live data/accounts."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='voicepad-selfhost-',dir=os.environ.get('TMPDIR')) as directory:
    root=Path(directory)
    for name in ['compose.yaml','.env.example','scripts/setup.sh']:
        target=root/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy(ROOT/name,target)
    subprocess.run(['sh','scripts/setup.sh'],cwd=root,check=True)
    envfile=root/'.env'
    envfile.write_text(envfile.read_text().replace('8791','18791'))
    override=root/'smoke.yaml'
    override.write_text('services:\n  voicepad:\n    image: voicepad:public-check\n')
    command=['docker','compose','-p','voicepad-public-smoke','-f','compose.yaml','-f','smoke.yaml']
    try:
        subprocess.run(command+['up','-d','--no-build'],cwd=root,check=True)
        base='http://localhost:18791/'
        for attempt in range(30):
            try:
                with urllib.request.urlopen(base+'healthz',timeout=2) as response:assert json.load(response)['ok']
                break
            except Exception:
                if attempt==29:raise
                time.sleep(1)
        for page in ['','admin','profiles','usage','core.mjs']:
            with urllib.request.urlopen(base+page,timeout=5) as response:assert response.status==200
        headers={'X-Requested-With':'voicepad','Content-Type':'application/json','Origin':'http://localhost:18791'}
        request=urllib.request.Request(base+'api/profiles/9',method='PUT',headers=headers,data=json.dumps({'name':'Smoke test','instructions':''}).encode())
        with urllib.request.urlopen(request,timeout=5) as response:assert json.load(response)['profiles'][0]['slot']==9
        # Read back the exact target after the mutation.
        with urllib.request.urlopen(base+'api/profiles',timeout=5) as response:assert json.load(response)['profiles'][0]['name']=='Smoke test'
        subprocess.run(command+['restart'],cwd=root,check=True)
        for attempt in range(30):
            try:
                with urllib.request.urlopen(base+'api/profiles',timeout=2) as response:assert json.load(response)['profiles'][0]['slot']==9
                break
            except Exception:
                if attempt==29:raise
                time.sleep(1)
        with urllib.request.urlopen(base+'api/status',timeout=5) as response:
            status=json.load(response);assert not status['credential_available'];assert status['max_seconds']==600
        print('Fresh self-host Compose: pages, CSRF-compatible mutations, readback and restart persistence passed. No provider credentials used.')
    finally:
        subprocess.run(command+['down'],cwd=root,check=True)
