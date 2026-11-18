"""Tailnet-only no-key deployment checks; provider calls are explicit options."""
import argparse
import json
from pathlib import Path
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--base', default='http://localhost:8791/', help='Service URL including trailing slash, e.g. https://your-host/')
parser.add_argument('--require-connected', action='store_true')
parser.add_argument('--transcribe', type=Path, help='Spoken WAV; consumes unknown subscription allowance')
parser.add_argument('--refresh', action='store_true', help='Exercise a real refresh-token rotation after your own login')
args = parser.parse_args()
for path in ['', 'admin', 'app.mjs', 'admin.mjs', 'core.mjs', 'styles.css', 'healthz']:
    with urllib.request.urlopen(args.base + path, timeout=15) as response:
        assert response.status == 200
        if path.endswith('.mjs'):
            assert 'javascript' in response.headers['content-type']
        print(path or 'index', response.status, response.headers['content-type'])
with urllib.request.urlopen(args.base + 'api/status', timeout=15) as response:
    result = json.load(response)
    print('keyless status', json.dumps(result))
    if args.require_connected:
        assert result['credential_available'], 'User must complete independent Codex login first'
with urllib.request.urlopen(args.base + 'api/admin/status', timeout=15) as response:
    public = json.load(response)
    assert not any(key in public for key in ['access_token', 'refresh_token', 'account_id', 'id_token'])
    safe = {key:value for key,value in public.items() if key != 'login'}
    safe['login_state'] = public['login']['state']
    print('admin status', json.dumps(safe))
for route in ['login', 'disconnect', 'refresh']:
    request = urllib.request.Request(args.base + 'api/admin/' + route, data=b'{}')
    try:
        urllib.request.urlopen(request, timeout=15)
        raise AssertionError('Mutation without custom CSRF header was allowed')
    except urllib.error.HTTPError as exc:
        assert exc.code == 403
print('mutation CSRF guards passed')
if args.refresh:
    request = urllib.request.Request(args.base + 'api/admin/refresh', data=b'{}', headers={'X-Requested-With':'voicepad'})
    with urllib.request.urlopen(request, timeout=40) as response:
        refreshed = json.load(response)
        assert refreshed['connected']
        print('real refresh succeeded; expiry:', refreshed['credential_expires_at'], 'last refresh:', refreshed['last_refresh_at'])
if args.transcribe:
    request = urllib.request.Request(args.base + 'api/transcribe', data=args.transcribe.read_bytes(), headers={
        'Content-Type':'audio/wav', 'X-Requested-With':'voicepad'})
    with urllib.request.urlopen(request, timeout=360) as response:
        print('real transcription', json.dumps(json.load(response)))
