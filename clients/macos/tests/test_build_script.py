"""Behavioral packaging tests with fake Apple tools, not native compilation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]

class BuildScriptTests(unittest.TestCase):
    def setup_tree(self, directory, fail_build=False, platform='Darwin'):
        root = Path(directory) / 'Voicepad source'
        for folder in ['scripts','Resources','Sources/VoicepadCore','Sources/Voicepad','tools']:
            (root / folder).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE/'scripts/build.sh', root/'scripts/build.sh')
        for script in (SOURCE/'scripts').glob('*.py'):
            shutil.copyfile(script, root/'scripts'/script.name)
        for name in ['Info.plist','Voicepad.entitlements']:
            shutil.copyfile(SOURCE/'Resources'/name, root/'Resources'/name)
        (root/'Sources/VoicepadCore/Core.swift').write_text('test core')
        (root/'Sources/Voicepad/App.swift').write_text('test app')
        scripts = {
            'uname': '#!/bin/sh\nif [ "$1" = -m ]; then printf "arm64\\n"; else printf "%s\\n" "$FAKE_PLATFORM"; fi\n',
            'xcrun': '''#!/usr/bin/env python3
import os,sys,json,pathlib
args=sys.argv[1:]
with open(os.environ['TOOL_LOG'],'a') as f:f.write(json.dumps(args)+'\\n')
if args[:1]==['--find']:print('/fake/swiftc')
elif args==['--sdk','macosx','--show-sdk-path']:print('/fake/Mac SDK')
elif args[:1]==['swift']:sys.exit('SwiftPM manifest deliberately unavailable')
elif args[:1]==['swiftc']:
 if os.environ['FAIL_BUILD']=='1':sys.exit(1)
 if '-o' in args:
  p=pathlib.Path(args[args.index('-o')+1]);p.parent.mkdir(parents=True,exist_ok=True);p.write_text('test executable')
else:sys.exit(1)
''',
            'codesign':'#!/bin/sh\nprintf "codesign %s\\n" "$*" >> "$TOOL_LOG"\n',
            'plutil':'#!/bin/sh\nexit 0\n',
        }
        for name,text in scripts.items():
            p=root/'tools'/name;p.write_text(text);p.chmod(0o755)
        env=dict(os.environ,PATH=str(root/'tools')+':'+os.environ['PATH'],TOOL_LOG=str(root/'calls'),FAIL_BUILD='1' if fail_build else '0',FAKE_PLATFORM=platform)
        env.pop('VOICEPAD_SERVER_URL', None)
        return root,env

    def test_build_embeds_default_or_configured_server_without_changing_source_plist(self):
        import plistlib
        for value,expected in [(None,'http://localhost:8791/'),
                               ('https://your-host/voicepad','https://your-host/voicepad/'),
                               ('http://127.0.0.1:8791/base','http://127.0.0.1:8791/base/'),
                               ('http://[::1]:8791/','http://[::1]:8791/'),
                               ('https://your-host/a%20b/','https://your-host/a%20b/')]:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root,env=self.setup_tree(directory)
                before=(root/'Resources/Info.plist').read_bytes()
                if value is not None: env['VOICEPAD_SERVER_URL']=value
                result=subprocess.run(['bash',str(root/'scripts/build.sh')],env=env,text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
                info=plistlib.loads((root/'dist/Voicepad.app/Contents/Info.plist').read_bytes())
                self.assertEqual(info.get('VoicepadServerURL'),expected)
                self.assertEqual((root/'Resources/Info.plist').read_bytes(),before)

    def test_invalid_server_is_rejected_before_compilation_and_old_app_is_preserved(self):
        invalid = ['', 'http://your-host/', 'http://192.168.1.5/', 'http://localhost.evil/',
                   'http://[::ffff:127.0.0.1]/', 'ftp://localhost/', '/relative/', 'https:///',
                   'https://user:pass@your-host/', 'https://@your-host/', 'https://your-host/?',
                   'https://your-host/?key=value', 'https://your-host/#', 'https://your-host/#fragment',
                   ' https://your-host/', 'https://your-host/\n', 'https://your-host/a b/',
                   'https://your-host\\evil/', 'https://your-host:0/', 'https://your-host:65536/',
                   'https://your-host:abc/', 'https://your-host:/', 'https://your-host/%zz/',
                   'https://%6cocalhost/', 'http://127.1/', 'http://2130706433/']
        for value in invalid:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root,env=self.setup_tree(directory)
                old=root/'dist/Voicepad.app/previous'
                old.parent.mkdir(parents=True);old.write_text('preserve')
                env['VOICEPAD_SERVER_URL']=value
                result=subprocess.run(['bash',str(root/'scripts/build.sh')],env=env,text=True,capture_output=True)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('VOICEPAD_SERVER_URL',result.stderr)
                self.assertEqual(old.read_text(),'preserve')
                self.assertFalse((root/'calls').exists(), 'Invalid configuration must fail before Apple tools')

    def test_release_bundle_metadata(self):
        import plistlib
        info=plistlib.loads((SOURCE/'Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'],'0.6.2')
        self.assertEqual(info['CFBundleVersion'],'15')
        self.assertEqual(info.get('VoicepadServerURL'),'http://localhost:8791/')
        ats=info.get('NSAppTransportSecurity',{})
        self.assertIs(ats.get('NSAllowsLocalNetworking'),True)
        self.assertIsNot(ats.get('NSAllowsArbitraryLoads'),True)

    def test_build_bypasses_broken_manifest_and_statically_links_core(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root,env=self.setup_tree(directory)
            result=subprocess.run(['bash',str(root/'scripts/build.sh')],cwd='/',env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            app=root/'dist/Voicepad.app'
            self.assertEqual((app/'Contents/MacOS/Voicepad').read_text(),'test executable')
            calls=(root/'calls').read_text().splitlines()
            compiler=[json.loads(line) for line in calls if line.startswith('["swiftc"')]
            self.assertEqual(len(compiler),2)
            self.assertIn('-static',compiler[0])
            self.assertIn('-emit-module',compiler[0])
            self.assertIn(str(root/'Sources/VoicepadCore/Core.swift'),compiler[0])
            self.assertIn('-parse-as-library',compiler[1])
            self.assertIn('arm64-apple-macosx13.0',compiler[1])
            self.assertIn('/fake/Mac SDK',compiler[1])
            self.assertTrue(any(s.endswith('libVoicepadCore.a') for s in compiler[1]))
            self.assertFalse(any(line.startswith('["swift",') for line in calls))
            self.assertTrue(any('codesign --verify' in line for line in calls))

    def test_compile_failure_does_not_create_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root,env=self.setup_tree(directory,True)
            result=subprocess.run(['bash',str(root/'scripts/build.sh')],env=env,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse((root/'dist/Voicepad.app').exists())

    def test_failed_build_preserves_old_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root,env=self.setup_tree(directory,True)
            old=root/'dist/Voicepad.app/previous';old.parent.mkdir(parents=True);old.write_text('preserve')
            subprocess.run(['bash',str(root/'scripts/build.sh')],env=env,capture_output=True)
            self.assertEqual(old.read_text(),'preserve')

    def test_extra_flags_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root,env=self.setup_tree(directory)
            r=subprocess.run(['bash',str(root/'scripts/build.sh'),'--skip'],env=env,capture_output=True)
            self.assertNotEqual(r.returncode,0)
            self.assertIn(b'no extra build flags',r.stderr)

    def test_linux_refuses_mac_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root,env=self.setup_tree(directory,platform='Linux')
            r=subprocess.run(['bash',str(root/'scripts/build.sh')],env=env,capture_output=True)
            self.assertNotEqual(r.returncode,0)
            self.assertIn(b'macOS',r.stderr)
            self.assertFalse((root/'calls').exists())

if __name__=='__main__':unittest.main()
