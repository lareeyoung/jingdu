#!/usr/bin/env python3
"""Offline regression checks. Never calls Security.framework or changes trust."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/sign-local-app.py"
spec = importlib.util.spec_from_file_location("local_signing", SCRIPT)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class LocalSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="jingdu-signing-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.certificate = b"public-test-certificate"
        self.state = {"version": 1, "bundleIdentifier": signing.BUNDLE_ID,
                      "certificateSHA1": hashlib.sha1(self.certificate).hexdigest().upper(),
                      "certificateSHA256": hashlib.sha256(self.certificate).hexdigest().upper(),
                      "keychainPassword": "isolated-test-password-" * 3, "trustConfigured": False}
        self.write(signing.CERT_NAME, self.certificate)
        self.write(signing.KEYCHAIN_NAME, b"offline-placeholder")
        signing.write_state(self.root, self.state)
        self.app = self.root / "镜读.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/Jingdu").write_bytes(b"offline-not-executable")
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": signing.BUNDLE_ID, "CFBundleExecutable": "Jingdu"}, stream)
        self.calls = []
        self.original_search = [str(self.root / "login keychain-db"), "/Library/Keychains/System.keychain"]
        self.search = self.original_search.copy()

    def write(self, name, data):
        path = self.root / name
        path.write_bytes(data)
        path.chmod(0o600)

    def run_fake(self, command, label, **kwargs):
        self.calls.append(command)
        if command[:4] == [signing.SECURITY, "list-keychains", "-d", "user"]:
            if len(command) > 4:
                self.assertEqual(command[4], "-s")
                self.search = command[5:]
            return ("\n".join(json.dumps(path) for path in self.search) + "\n").encode()
        extraction = [arg for arg in command if arg.startswith("--extract-certificates=")]
        if extraction:
            prefix = extraction[0].split("=", 1)[1]
            Path(prefix + "0").write_bytes(self.certificate)
        return b""

    def test_state_round_trip_is_private(self):
        self.assertEqual(signing.load_state(self.root), self.state)
        self.assertEqual((self.root / signing.STATE_NAME).stat().st_mode & 0o777, 0o600)

    def test_changed_certificate_is_rejected(self):
        self.write(signing.CERT_NAME, b"another-certificate")
        with self.assertRaises(signing.SigningError):
            signing.load_state(self.root)

    def test_wrong_state_type_is_rejected_without_contents(self):
        self.write(signing.STATE_NAME, b"[\"secret-value\"]")
        with self.assertRaises(signing.SigningError) as error:
            signing.load_state(self.root)
        self.assertNotIn("secret-value", str(error.exception))

    def test_open_permissions_are_rejected(self):
        (self.root / signing.STATE_NAME).chmod(0o644)
        with self.assertRaises(signing.SigningError):
            signing.load_state(self.root)

    def test_symlink_state_is_rejected(self):
        path = self.root / signing.STATE_NAME
        other = self.root / "other.json"
        path.rename(other)
        path.symlink_to(other)
        with self.assertRaises(signing.SigningError):
            signing.load_state(self.root)

    def test_prepare_reuses_existing_identity_without_keychain_calls(self):
        before = (self.root / signing.STATE_NAME).read_bytes()
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run") as run:
            self.assertEqual(signing.prepare(self.root), self.state)
        bridge.assert_not_called()
        run.assert_not_called()
        self.assertEqual(before, (self.root / signing.STATE_NAME).read_bytes())

    def test_partial_prepare_never_replaces_identity(self):
        (self.root / signing.STATE_NAME).unlink()
        with patch.object(signing, "Keychain") as bridge, self.assertRaises(signing.SigningError):
            signing.prepare(self.root)
        bridge.assert_not_called()
        self.assertEqual((self.root / signing.CERT_NAME).read_bytes(), self.certificate)

    def test_failed_prepare_cleans_temporary_keys_and_preserves_partial_identity(self):
        directory = self.root / "incomplete"
        directory.mkdir(mode=0o700)
        (directory / "build.lock").touch(mode=0o600)

        def fail_package(command, label, **kwargs):
            if command[1] == "req":
                Path(command[command.index("-keyout") + 1]).write_bytes(b"temporary-test-private-key")
            elif command[1] == "x509":
                Path(command[command.index("-out") + 1]).write_bytes(self.certificate)
            elif command[1] == "pkcs12":
                raise signing.SigningError("isolated package failure")
            return b""

        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=fail_package):
            with patch.object(signing, "keychain_preferences", return_value=(b"original", b"original")):
                with self.assertRaises(signing.SigningError):
                    signing.prepare(directory)
        bridge.return_value.create.assert_not_called()
        bridge.return_value.close.assert_called_once()
        self.assertEqual({p.name for p in directory.iterdir()}, {"build.lock", signing.CERT_NAME})
        self.assertEqual((directory / signing.CERT_NAME).read_bytes(), self.certificate)
        with patch.object(signing, "Keychain") as second_bridge, self.assertRaises(signing.SigningError):
            signing.prepare(directory)
        second_bridge.assert_not_called()

    def test_user_code_sign_and_application_constraints_are_explicit(self):
        self.assertEqual(signing.trust_command(self.root), ["/usr/bin/security", "add-trusted-cert",
            "-r", "trustRoot", "-p", "codeSign", "-a", "/usr/bin/codesign", "-k",
            str(self.root / signing.KEYCHAIN_NAME), str(self.root / signing.CERT_NAME)])

    def test_designated_requirement_pins_identifier_and_certificate(self):
        expected = 'identifier "local.jingdu.studio" and certificate leaf = H"' + self.state["certificateSHA1"] + '"'
        self.assertEqual(signing.requirement(self.state), expected)

    def test_ordinary_sign_cannot_grant_first_trust(self):
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run") as run:
            with self.assertRaises(signing.SigningError):
                signing.sign(self.root, self.state, self.app)
        bridge.assert_not_called()
        run.assert_not_called()

    def test_wrong_app_is_rejected_before_trust_mutation(self):
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "another.application", "CFBundleExecutable": "Jingdu"}, stream)
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run") as run:
            with self.assertRaises(signing.SigningError):
                signing.sign(self.root, self.state, self.app, establish_trust=True)
        bridge.assert_not_called()
        run.assert_not_called()

    def test_existing_sign_never_rewrites_trust_and_locks_keychain(self):
        state = dict(self.state, trustConfigured=True)
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=self.run_fake):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                signing.sign(self.root, state, self.app)
        self.assertFalse(any("add-trusted-cert" in command for command in self.calls))
        command = next(command for command in self.calls if "--sign" in command)
        self.assertEqual(command[command.index("--sign") + 1], state["certificateSHA1"])
        self.assertEqual(command[command.index("--keychain") + 1], str(self.root / signing.KEYCHAIN_NAME))
        self.assertEqual(command[command.index("--requirements") + 1], "=designated => " + signing.requirement(state))
        bridge.return_value.lock.assert_called_once_with(bridge.return_value.unlock.return_value)
        bridge.return_value.close.assert_called_once()
        self.assertNotIn(state["keychainPassword"], output.getvalue())
        self.assertTrue(any("--test-requirement" in command for command in self.calls))
        self.assertEqual(self.search, self.original_search)
        self.assertFalse(any("default-keychain" in command for command in self.calls))

    def test_subtitle_engine_is_signed_before_app_with_same_identity(self):
        engine = self.app / "Contents/Resources/SubtitleEngine/whisper-cli"
        engine.parent.mkdir(parents=True)
        engine.write_bytes(b"offline-engine")
        with patch.object(signing, "Keychain"), patch.object(signing, "run", side_effect=self.run_fake):
            with contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, dict(self.state, trustConfigured=True), self.app)
        signs = [command for command in self.calls if "--sign" in command]
        self.assertEqual([command[-1] for command in signs], [str(engine), str(self.app)])
        self.assertTrue(all(command[command.index("--sign") + 1] == self.state["certificateSHA1"] for command in signs))
        self.assertEqual(signs[-1][signs[-1].index("--requirements") + 1], "=designated => " + signing.requirement(self.state))
        self.assertTrue(any("--verify" in command and "--deep" in command for command in self.calls))
        self.assertFalse(any("add-trusted-cert" in command for command in self.calls))
        self.assertEqual(self.search, self.original_search)

    def test_trust_and_sign_records_grant_only_after_success(self):
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=self.run_fake):
            with contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, self.state, self.app, establish_trust=True)
        self.assertEqual(self.calls[0], signing.trust_command(self.root))
        self.assertTrue(signing.load_state(self.root)["trustConfigured"])
        bridge.return_value.lock.assert_called_once()

    def test_failed_trust_is_not_recorded_and_never_signs(self):
        def fail(command, label, **kwargs):
            self.calls.append(command)
            raise signing.SigningError("test denial")
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=fail):
            with self.assertRaises(signing.SigningError), contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, self.state, self.app, establish_trust=True)
        self.assertFalse(signing.load_state(self.root)["trustConfigured"])
        self.assertEqual(self.calls, [signing.trust_command(self.root)])
        bridge.return_value.lock.assert_called_once()

    def test_failed_sign_stops_without_adhoc_fallback_and_locks(self):
        def fail(command, label, **kwargs):
            if "--sign" in command:
                self.calls.append(command)
                self.assertIn(str(self.root / signing.KEYCHAIN_NAME), self.search)
                raise signing.SigningError("test signing failure")
            return self.run_fake(command, label, **kwargs)
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=fail):
            with self.assertRaises(signing.SigningError):
                signing.sign(self.root, dict(self.state, trustConfigured=True), self.app)
        sign_calls = [command for command in self.calls if "--sign" in command]
        self.assertEqual(len(sign_calls), 1)
        self.assertNotIn("-", sign_calls[0])
        self.assertEqual(self.search, self.original_search)
        bridge.return_value.lock.assert_called_once()
        bridge.return_value.close.assert_called_once()

    def test_unexpected_embedded_certificate_is_rejected(self):
        def wrong_cert(command, label, **kwargs):
            result = self.run_fake(command, label, **kwargs)
            extraction = [arg for arg in command if arg.startswith("--extract-certificates=")]
            if extraction:
                prefix = extraction[0].split("=", 1)[1]
                Path(prefix + "0").write_bytes(b"another certificate")
            return result
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=wrong_cert):
            with self.assertRaises(signing.SigningError):
                signing.sign(self.root, dict(self.state, trustConfigured=True), self.app)
        bridge.return_value.lock.assert_called_once()
        self.assertEqual(self.search, self.original_search)

    def test_sign_temporarily_registers_identity_and_restores_on_success(self):
        def check_lookup(command, label, **kwargs):
            if command[0] == signing.CODESIGN:
                self.assertIn(str(self.root / signing.KEYCHAIN_NAME), self.search)
                self.assertEqual(self.search[:-1], self.original_search)
            return self.run_fake(command, label, **kwargs)
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=check_lookup):
            with contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, dict(self.state, trustConfigured=True), self.app)
        self.assertEqual(self.search, self.original_search)
        updates = [command for command in self.calls if command[:2] == [signing.SECURITY, "list-keychains"] and "-s" in command]
        self.assertEqual(len(updates), 2)
        bridge.return_value.lock.assert_called_once()

    def test_existing_search_membership_is_left_untouched(self):
        self.search.insert(1, str(self.root / signing.KEYCHAIN_NAME))
        before = self.search.copy()
        with patch.object(signing, "Keychain"), patch.object(signing, "run", side_effect=self.run_fake):
            with contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, dict(self.state, trustConfigured=True), self.app)
        self.assertEqual(self.search, before)
        self.assertFalse(any(command[:2] == [signing.SECURITY, "list-keychains"] and "-s" in command
                             for command in self.calls))

    def test_cleanup_preserves_concurrent_user_search_changes(self):
        added = str(self.root / "user added keychain-db")
        def change_during_sign(command, label, **kwargs):
            result = self.run_fake(command, label, **kwargs)
            if "--sign" in command:
                self.search.remove(self.original_search[0])
                self.search.insert(0, added)
            return result
        with patch.object(signing, "Keychain"), patch.object(signing, "run", side_effect=change_during_sign):
            with contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, dict(self.state, trustConfigured=True), self.app)
        self.assertEqual(self.search, [added, self.original_search[1]])

    def test_successful_trust_with_failed_sign_is_not_recorded(self):
        def fail_sign(command, label, **kwargs):
            if "--sign" in command:
                self.calls.append(command)
                raise signing.SigningError("test signing failure after trust")
            return self.run_fake(command, label, **kwargs)
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=fail_sign):
            with self.assertRaises(signing.SigningError), contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, self.state, self.app, establish_trust=True)
        self.assertFalse(signing.load_state(self.root)["trustConfigured"])
        self.assertEqual(self.search, self.original_search)
        bridge.return_value.lock.assert_called_once()

    def test_trust_completion_is_written_only_after_embedded_certificate_verification(self):
        def check_before_completion(command, label, **kwargs):
            self.assertFalse(signing.load_state(self.root)["trustConfigured"])
            return self.run_fake(command, label, **kwargs)
        with patch.object(signing, "Keychain"), patch.object(signing, "run", side_effect=check_before_completion):
            with contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, self.state, self.app, establish_trust=True)
        self.assertTrue(signing.load_state(self.root)["trustConfigured"])

    def test_trust_with_failed_verification_is_not_recorded(self):
        def fail_verification(command, label, **kwargs):
            if "--verify" in command:
                self.calls.append(command)
                raise signing.SigningError("test verification failure after trust")
            return self.run_fake(command, label, **kwargs)
        with patch.object(signing, "Keychain") as bridge, patch.object(signing, "run", side_effect=fail_verification):
            with self.assertRaises(signing.SigningError), contextlib.redirect_stdout(io.StringIO()):
                signing.sign(self.root, self.state, self.app, establish_trust=True)
        self.assertFalse(signing.load_state(self.root)["trustConfigured"])
        self.assertEqual(self.search, self.original_search)
        bridge.return_value.lock.assert_called_once()


if __name__ == "__main__":
    unittest.main()
