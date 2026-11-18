import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class SetupTests(unittest.TestCase):
    def test_setup_works_without_host_python(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'scripts').mkdir();tools=root/'tools';tools.mkdir()
            shutil.copy(ROOT/'scripts/setup.sh',root/'scripts/setup.sh')
            shutil.copy(ROOT/'.env.example',root/'.env.example')
            for name in ['dirname','id','cp','mkdir','chmod','mktemp','mv','rm']:
                tool=shutil.which(name)
                self.assertIsNotNone(tool)
                assert tool is not None
                (tools/name).symlink_to(tool)
            result=subprocess.run(['/bin/sh','scripts/setup.sh'],cwd=root,
                                  env={**os.environ,'PATH':str(tools)},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('VOICEPAD_UID='+str(os.getuid()),(root/'.env').read_text())
            self.assertIn('VOICEPAD_GID='+str(os.getgid()),(root/'.env').read_text())
            self.assertTrue((root/'data').is_dir())

    def test_fresh_checkout_setup_is_private_and_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'scripts').mkdir()
            shutil.copy(ROOT/'scripts/setup.sh',root/'scripts/setup.sh')
            shutil.copy(ROOT/'.env.example',root/'.env.example')
            result=subprocess.run(['sh','scripts/setup.sh'],cwd=root,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((root/'.env').stat().st_mode&0o777,0o600)
            self.assertEqual((root/'data').stat().st_mode&0o777,0o700)
            self.assertIn('VOICEPAD_UID='+str(os.getuid()),(root/'.env').read_text())
            (root/'.env').write_text('CUSTOM=do-not-overwrite\n')
            subprocess.run(['sh','scripts/setup.sh'],cwd=root,check=True,capture_output=True)
            self.assertEqual((root/'.env').read_text(),'CUSTOM=do-not-overwrite\n')
