"""Check tracked/public candidate files without printing credential values.

This is a lightweight regression guard, not a replacement for secret review.
OAuth client IDs are public identifiers; test JWTs are synthetic fixtures.
"""
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
files = subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=ROOT).decode().split('\0')
patterns = {
    'private deployment reference': re.compile(r'\b' + 'bob' + r'-home\b|' + 'tail' + r'dba06|/Users/' + 'soup' + r'tik', re.I),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'provider credential': re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{30,}|sk-(?:proj-)?[A-Za-z0-9_-]{24,})'),
}
errors=[]
for name in files:
    if not name:continue
    path=ROOT/name
    if not path.is_file():continue
    if any(part in {'.venv','.build','dist','.hermes','secrets','data','.dev-data','__pycache__'} for part in pathlib.PurePosixPath(name).parts):
        errors.append((name,'private/generated directory'));continue
    if pathlib.Path(name).name in {'.env','oauth.json','codex.json','metrics.json','profiles.json','formatting-metrics.json'}:
        errors.append((name,'runtime file'));continue
    if name=='scripts/check_public_tree.py':continue
    text=path.read_text(errors='replace')
    for label,pattern in patterns.items():
        if pattern.search(text):errors.append((name,label))
if errors:
    for name,reason in errors:print(name+': '+reason)
    raise SystemExit('Public-tree scan failed; values were not printed.')
print(f'Public-tree scan passed for {len([f for f in files if f])} candidate files (no credential values printed).')
