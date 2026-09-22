#!/usr/bin/env python3
"""Build publication checks; all compilers/signers are fakes, no trust changes.

Run: python3 Tests/BuildSigningTests.py
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "build.command"


class BuildSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="jingdu-build-tests-")
        self.root = Path(self.temporary.name)
        self.project = self.root / "source with spaces"
        self.project.mkdir()
        shutil.copy2(SOURCE, self.project / "build.command")
        for directory in ("Sources", "Resources", "Scripts"):
            (self.project / directory).mkdir()
        (self.project / "Sources/App.swift").write_text("// mock compiler input\n")
        (self.project / "Resources/Info.plist").write_text("mock plist\n")
        (self.project / "Resources/AppIcon.icns").write_bytes(b"mock icon")
        (self.project / "Resources/SubtitleEngine").mkdir()
        (self.project / "Resources/SubtitleEngine/whisper-cli").write_bytes(b"mock subtitle engine")
        (self.project / "Resources/SubtitleEngine/._whisper-cli").write_bytes(b"mock exfat metadata")
        (self.project / "Scripts/sign-local-app.py").write_text("# never executed\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.user_home = self.root / "test user"
        self.user_home.mkdir()
        self.installed = self.user_home / "Applications/镜读.app"
        self.installed.mkdir(parents=True)
        (self.installed / "previous-version").write_text("old signed application")
        self.events = self.root / "events.jsonl"
        self.environment = dict(os.environ, HOME=str(self.user_home),
                                PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                TEST_EVENTS=str(self.events),
                                TEST_INSTALLED=str(self.installed))
        self.environment.pop("JINGDU_APP_OUTPUT", None)
        self.stub("xcrun", """
import json, os, pathlib, sys
with open(os.environ['TEST_EVENTS'], 'a') as stream:
    stream.write(json.dumps({'kind': 'compile', 'args': sys.argv[1:]}) + '\\n')
if os.environ.get('TEST_COMPILE_FAILURE'):
    sys.exit(31)
target = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
target.write_text('new executable')
""")
        self.stub("python3", """
import json, os, pathlib, sys
if len(sys.argv) > 1 and sys.argv[1] == 'Scripts/sign-local-app.py':
    app = pathlib.Path(sys.argv[3])
    old = pathlib.Path(os.environ['TEST_INSTALLED']) / 'previous-version'
    with open(os.environ['TEST_EVENTS'], 'a') as stream:
        stream.write(json.dumps({'kind': 'sign', 'args': sys.argv[1:],
                                'old_exists': old.exists(),
                                'candidate_exists': (app / 'Contents/MacOS/Jingdu').exists()}) + '\\n')
    if os.environ.get('TEST_SIGN_FAILURE'):
        sys.exit(32)
    (app / 'fixed-identity-verified').write_text('verified by fake signer')
    sys.exit(0)
os.execv(REAL_PYTHON, [REAL_PYTHON] + sys.argv[1:])
""".replace("REAL_PYTHON", repr(sys.executable)))
        self.stub("codesign", """
import sys
sys.exit('Unexpected direct codesign invocation')
""")

    def tearDown(self):
        self.temporary.cleanup()

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o700)

    def run_build(self, *arguments, **environment):
        return subprocess.run(["/bin/zsh", str(self.project / "build.command"), *arguments],
                              cwd=self.root, env=dict(self.environment, **environment),
                              text=True, capture_output=True, timeout=20)

    def read_events(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []

    def assert_old_preserved(self):
        self.assertEqual((self.installed / "previous-version").read_text(), "old signed application")
        self.assertEqual(list(self.installed.parent.glob(".jingdu-build.*")), [])

    def test_normal_build_signs_before_publishing(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.read_events()
        self.assertEqual([event["kind"] for event in events], ["compile", "sign"])
        sign = events[1]
        self.assertEqual(sign["args"][:2], ["Scripts/sign-local-app.py", "sign"])
        self.assertNotEqual(Path(sign["args"][2]), self.installed)
        self.assertTrue(sign["old_exists"])
        self.assertTrue(sign["candidate_exists"])
        self.assertTrue((self.installed / "fixed-identity-verified").exists())
        self.assertFalse((self.installed / "previous-version").exists())
        self.assertEqual((self.installed / "Contents/Resources/SubtitleEngine/whisper-cli").read_bytes(), b"mock subtitle engine")
        self.assertFalse((self.installed / "Contents/Resources/SubtitleEngine/._whisper-cli").exists())
        self.assertEqual((self.installed / "Contents/Resources/AppIcon.icns").read_bytes(), b"mock icon")
        self.assertEqual(list(self.installed.parent.glob(".jingdu-build.*")), [])

    def test_sign_failure_preserves_installed_app(self):
        result = self.run_build(TEST_SIGN_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([event["kind"] for event in self.read_events()], ["compile", "sign"])
        self.assert_old_preserved()

    def test_compiler_failure_preserves_installed_app(self):
        result = self.run_build(TEST_COMPILE_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([event["kind"] for event in self.read_events()], ["compile"])
        self.assert_old_preserved()

    def test_prepare_publishes_candidate_without_signer(self):
        candidate = self.root / "review candidate/镜读.app"
        result = self.run_build("--prepare", JINGDU_APP_OUTPUT=str(candidate))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([event["kind"] for event in self.read_events()], ["compile"])
        self.assertTrue((candidate / "Contents/MacOS/Jingdu").exists())
        self.assertFalse((candidate / "fixed-identity-verified").exists())
        self.assert_old_preserved()

    def test_prepare_requires_explicit_output(self):
        result = self.run_build("--prepare")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read_events(), [])
        self.assert_old_preserved()

    def test_prepare_rejects_installed_destination_and_aliases(self):
        alias = self.root / "installed-alias.app"
        alias.symlink_to(self.installed)
        paths = [self.installed, alias, self.installed / "nested.app",
                 self.installed.parent / "unused/../镜读.app"]
        for path in paths:
            with self.subTest(path=path):
                result = self.run_build("--prepare", JINGDU_APP_OUTPUT=str(path))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.read_events(), [])
                self.assert_old_preserved()

    def test_rejects_unknown_or_extra_arguments(self):
        for arguments in [("--adhoc",), ("--prepare", "--prepare"), ("anything",)]:
            with self.subTest(arguments=arguments):
                result = self.run_build(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.read_events(), [])
                self.assert_old_preserved()


if __name__ == "__main__":
    unittest.main(verbosity=2)
