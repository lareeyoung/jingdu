#!/usr/bin/env python3
"""Offline release checks: fake compiler/codesign only; no keychain or network."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "Scripts/package-release.py"
spec = importlib.util.spec_from_file_location("package_release", MODULE_PATH)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="jingdu-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.root = self.work / "source with spaces"
        for directory in ("Sources", "Tests", "Scripts", "Resources/SubtitleEngine"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        self.write("build.command", "#!/bin/zsh\n# fake compiler input\n")
        self.write("Sources/JingduApp.swift", "// synthetic application\n")
        self.write("Sources/ScriptRelay.swift", 'var baseURL = ""\n')
        self.write("Scripts/package-release.py", "# fixture packaging script\n")
        self.write("Scripts/prepare-subtitle-engine.py", "# fixture model preparation\n")
        self.write("Scripts/DISTRIBUTION.md", "Notarized: false. No private signing identity is shared.\n")
        self.write("README.md", "Shared source fixture\n")
        self.write(".gitignore", "._*\n*.bin\n")
        self.write("Tests/Example.swift", "// synthetic test\n")
        self.write("Resources/AppIcon.icns", "fake icon")
        self.write("Resources/SubtitleEngine/whisper-cli", "fake arm64 decoder")
        for name in release.ENGINE_FILES:
            self.write("Resources/SubtitleEngine/" + name, "fixture license/notice\n")
        self.info = {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "9",
                     "LSMinimumSystemVersion": "14.0", "CFBundleIdentifier": "local.jingdu.studio"}
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.commands = []
        self.sign_fail = False
        self.external_dependency = False
        self.extra_bundle_file = False
        self.arch = "arm64"

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def fake_command(self, arguments, *, cwd=None, env=None):
        self.commands.append(list(arguments))
        program = Path(arguments[0]).name
        if program == "lipo":
            return self.arch + "\n"
        if program == "otool":
            dependency = "/opt/unavailable/lib.dylib" if self.external_dependency else "/usr/lib/libSystem.B.dylib"
            return str(arguments[-1]) + ":\n\t" + dependency + " (compatibility version 1.0.0)\n"
        if program == "zsh":
            self.assertEqual(arguments[1:], ["build.command", "--prepare"])
            self.assertNotEqual(cwd, self.root)
            app = Path(env["JINGDU_APP_OUTPUT"])
            self.assertTrue(app.is_relative_to(self.work))
            self.assertEqual(env["COPYFILE_DISABLE"], "1")
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/Jingdu").write_bytes(b"synthetic arm64 main")
            (app / "Contents/MacOS/Jingdu").chmod(0o755)
            shutil.copyfile(cwd / "Resources/Info.plist", app / "Contents/Info.plist")
            shutil.copytree(cwd / "Resources", app / "Contents/Resources")
            (app / "Contents/Resources/Info.plist").unlink()
            if self.extra_bundle_file:
                (app / "Contents/Resources/private-account.json").write_text("must never ship")
            return "fake unsigned candidate built\n"
        if program == "codesign":
            if "--sign" in arguments:
                self.assertEqual(arguments[arguments.index("--sign") + 1], "-")
                if self.sign_fail:
                    raise release.ReleaseError("synthetic signer failure")
            return "Signature=adhoc\n" if "--display" in arguments else ""
        self.fail("Unexpected command: " + program)

    def make_package(self, folder="release", **options):
        with patch.object(release.sys, "platform", "darwin"):
            return release.package(self.root, self.work / folder, run=self.fake_command, **options)

    def archive(self, output, suffix):
        with zipfile.ZipFile(next(output.glob("*" + suffix + ".zip"))) as archive:
            return {name: archive.read(name) for name in archive.namelist()}

    def test_source_allowlist_excludes_private_generated_and_metadata_files(self):
        for relative in ("Sources/._JingduApp.swift", "Resources/._AppIcon.icns", ".DS_Store",
                         "Sources/private-account.json", "Library/library.json", "BuildSigning/identity.json",
                         "BuildSigning/private.p12", "model.bin", "film.mp4", "Tests/__pycache__/test.pyc",
                         "验证记录-1.2.3.md", "README-模型.md"):
            self.write(relative, "not source")
        output = self.make_package(source_only=True)
        self.assertEqual(self.commands, [])
        contents = self.archive(output, "source")
        names = "\n".join(contents)
        for excluded in ("._", "private-account", "BuildSigning", "Library/", "model.bin", "film.mp4", "__pycache__", "验证记录", "README-模型", "/whisper-cli"):
            self.assertNotIn(excluded, names)
        self.assertTrue(any(name.endswith("Sources/JingduApp.swift") for name in contents))
        self.assertTrue(any(name.endswith("LICENSE-whisper.cpp") for name in contents))
        metadata = json.loads((output / "RELEASE.json").read_text())
        self.assertFalse(metadata["notarized"])
        self.assertFalse(metadata["modelBundled"])
        self.assertIsNone(metadata["signature"])

    def test_source_archive_is_reproducible_and_checksums_are_correct(self):
        first = self.make_package("first", source_only=True)
        second = self.make_package("second", source_only=True)
        self.assertEqual(next(first.glob("*.zip")).read_bytes(), next(second.glob("*.zip")).read_bytes())
        for line in (first / "SHA256SUMS").read_text().splitlines():
            digest, filename = line.split("  ")
            self.assertEqual(release.sha256(first / filename), digest)

    def test_source_archive_includes_only_approved_screenshot_documentation(self):
        expected = {"docs/screenshots/" + name for name in
                    ("overview.jpg", "script.jpg", "subtitles.jpg", "remix.jpg", "README.md")}
        for relative in expected:
            self.write(relative, "approved screenshot fixture: " + relative)
        for relative in ("docs/private-notes.md", "docs/screenshots/unreviewed.jpg",
                         "docs/screenshots/._overview.jpg", "docs/screenshots/source-video.mp4"):
            self.write(relative, "must not ship")
        output = self.make_package(source_only=True)
        contents = self.archive(output, "source")
        documentation = {name.split("/", 1)[1]: data for name, data in contents.items()
                         if name.split("/", 1)[1].startswith("docs/")}
        self.assertEqual(set(documentation), expected)
        for relative, data in documentation.items():
            self.assertEqual(data, (self.root / relative).read_bytes())

    def test_screenshot_allowlist_retains_symlink_and_text_privacy_checks(self):
        external = self.work / "external.jpg"; external.write_bytes(b"private fixture")
        link = self.root / "docs/screenshots/overview.jpg"
        link.parent.mkdir(parents=True)
        link.symlink_to(external)
        with self.assertRaisesRegex(release.ReleaseError, "普通文件"):
            self.make_package(source_only=True)
        link.unlink()
        self.write("docs/screenshots/README.md", '// /Us' + 'ers/private-person/Documents/video\n')
        with self.assertRaisesRegex(release.ReleaseError, "个人"):
            self.make_package(source_only=True)

    def test_full_release_only_signs_temporary_app_ad_hoc(self):
        original_engine = (self.root / "Resources/SubtitleEngine/whisper-cli").read_bytes()
        output = self.make_package()
        signatures = [item for item in self.commands if "--sign" in item]
        self.assertEqual(len(signatures), 2)
        self.assertTrue(all(item[item.index("--sign") + 1] == "-" for item in signatures))
        self.assertTrue(all(Path(item[-1]).is_relative_to(self.work) for item in signatures))
        self.assertFalse(any("security" in item[0] or "sign-local-app.py" in " ".join(item) for item in self.commands))
        binary = self.archive(output, "macOS-arm64")
        self.assertTrue(any(name.endswith("镜读.app/Contents/MacOS/Jingdu") for name in binary))
        self.assertTrue(any(name.endswith("/whisper-cli") for name in binary))
        self.assertTrue(any(name.endswith("安装与模型准备.md") for name in binary))
        self.assertTrue(any(name.endswith("Scripts/prepare-subtitle-engine.py") for name in binary))
        self.assertEqual((self.root / "Resources/SubtitleEngine/whisper-cli").read_bytes(), original_engine)
        self.assertEqual(json.loads((output / "RELEASE.json").read_text())["signature"], "ad-hoc")

    def test_signature_failure_publishes_nothing_and_preserves_old_files(self):
        installed = self.work / "previous-install.app"; installed.mkdir()
        marker = installed / "old-data"; marker.write_text("unchanged")
        self.sign_fail = True
        with self.assertRaises(release.ReleaseError):
            self.make_package()
        self.assertFalse((self.work / "release").exists())
        self.assertEqual(marker.read_text(), "unchanged")
        self.assertEqual(list(self.work.glob(".jingdu-release-*")), [])

    def test_private_endpoint_blocks_packaging_but_test_fixture_addresses_are_allowed(self):
        self.write("Tests/Addresses.swift", 'let fixture = "http://' + '10.20.30.40"\n')
        self.make_package("allowed", source_only=True)
        self.write("Sources/ScriptRelay.swift", 'var baseURL = "http://' + '10.1.2.3:8801"\n')
        with self.assertRaisesRegex(release.ReleaseError, "内网"):
            self.make_package()
        self.assertFalse((self.work / "release").exists())

    def test_personal_path_and_private_key_material_are_rejected(self):
        self.write("Sources/Personal.swift", '// /Us' + 'ers/private-person/Documents/video\n')
        with self.assertRaisesRegex(release.ReleaseError, "个人"):
            self.make_package(source_only=True)
        (self.root / "Sources/Personal.swift").unlink()
        self.write("Scripts/notes.md", "-----BEGIN " + "PRIVATE KEY-----\nnot-a-real-key\n")
        with self.assertRaisesRegex(release.ReleaseError, "私钥"):
            self.make_package(source_only=True)

    def test_symlink_cannot_pull_files_from_outside_the_project(self):
        external = self.work / "external.swift"; external.write_text("private fixture")
        (self.root / "Sources/Link.swift").symlink_to(external)
        with self.assertRaisesRegex(release.ReleaseError, "普通文件"):
            self.make_package(source_only=True)

    def test_existing_output_and_application_paths_are_not_overwritten(self):
        output = self.work / "release"; output.mkdir(); (output / "keep").write_text("safe")
        with self.assertRaises(release.ReleaseError):
            self.make_package(source_only=True)
        self.assertEqual((output / "keep").read_text(), "safe")
        with self.assertRaisesRegex(release.ReleaseError, "Applications"):
            self.make_package("Installed.app/output", source_only=True)

    def test_unexpected_bundle_files_and_dependencies_block_distribution(self):
        self.external_dependency = True
        with self.assertRaisesRegex(release.ReleaseError, "非系统"):
            self.make_package("dependency-failure")
        self.external_dependency = False; self.extra_bundle_file = True
        with self.assertRaisesRegex(release.ReleaseError, "清单"):
            self.make_package("bundle-failure")
        self.assertFalse((self.work / "dependency-failure").exists())
        self.assertFalse((self.work / "bundle-failure").exists())

    def test_source_change_during_build_prevents_stale_publication(self):
        def changing_command(arguments, **options):
            result = self.fake_command(arguments, **options)
            if "--verify" in arguments:
                self.write("Sources/JingduApp.swift", "// new edit during compilation\n")
            return result
        with patch.object(release.sys, "platform", "darwin"):
            with self.assertRaisesRegex(release.ReleaseError, "源码清单或内容发生变化"):
                release.package(self.root, self.work / "release", run=changing_command)
        self.assertFalse((self.work / "release").exists())

    def test_unknown_arguments_are_rejected_without_packaging(self):
        result = subprocess.run([sys.executable, str(MODULE_PATH), "--unknown-option"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments", result.stderr)

    def test_wrong_architecture_is_rejected_before_building(self):
        self.arch = "x86_64"
        with self.assertRaisesRegex(release.ReleaseError, "arm64"):
            self.make_package()
        self.assertFalse(any(Path(item[0]).name == "zsh" for item in self.commands))


if __name__ == "__main__":
    unittest.main()
