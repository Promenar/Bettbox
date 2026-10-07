"""本机密钥创建的故障边界测试，不调用真实钥匙串或生成真实密钥。"""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('android_signing', Path(__file__).parents[1] / 'create_android_signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class AndroidSigningTest(unittest.TestCase):
    def exercise(self, failure=None):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            keytool = home / 'jdk/bin/keytool'
            keytool.parent.mkdir(parents=True)
            keytool.touch()
            keychain = home / 'Library/Keychains/login.keychain-db'
            keychain.parent.mkdir(parents=True)
            keychain.touch()
            commands = []
            state = {'replaced': False, 'stored': False}
            public_password = 'PUBLIC-FIXTURE-PASSWORD'
            def fake_command(argv, *, data=None):
                commands.append((argv, data))
                code, output = 0, b''
                if argv == ['/usr/bin/security', '-i']:
                    state['stored'] = True
                    if failure == 'store-timeout':
                        raise subprocess.TimeoutExpired('模拟写入超时', 1)
                    if failure == 'store-error':
                        code = 1
                elif '-w' in argv:
                    if failure == 'timeout':
                        raise subprocess.TimeoutExpired('模拟钥匙串查询', 1)
                    output = b'different' if failure == 'verification' or state['replaced'] else public_password.encode() + b'\n'
                elif 'find-generic-password' in argv:
                    code = 0 if failure == 'existing' or state['stored'] else 44
                elif '-v' in argv:
                    output = str(home / 'jdk').encode()
                elif '-genkeypair' in argv:
                    if failure in ('keytool', 'replacement'):
                        state['replaced'] = failure == 'replacement'
                        code = 1
                    else:
                        Path(argv[argv.index('-keystore') + 1]).write_bytes(b'PRIVATE-KEY-FIXTURE')
                elif '-exportcert' in argv:
                    output = b'PUBLIC-CERT-FIXTURE'
                    if failure == 'receipt':
                        directory = home / 'Library/Application Support/BettboxSigning'
                        (directory / 'android-release.json').mkdir()
                return subprocess.CompletedProcess(argv, code, stdout=output, stderr=b'')
            output = io.StringIO()
            with patch.object(Path, 'home', return_value=home), patch.object(signing, 'command', fake_command), patch.object(signing.secrets, 'token_hex', return_value=public_password), patch.object(sys, 'argv', ['fixture', '--execute']), contextlib.redirect_stdout(output):
                if failure:
                    with self.assertRaises((RuntimeError, OSError, subprocess.SubprocessError)): signing.main()
                else:
                    signing.main()
            self.assertNotIn(public_password, output.getvalue())
            self.assertTrue(all(public_password not in ' '.join(argv) for argv, _ in commands))
            directory = home / 'Library/Application Support/BettboxSigning'
            if failure:
                self.assertEqual((directory / 'android-release.p12').exists(), failure == 'receipt')
                if state['stored']:
                    self.assertIn('partial-requires-review', (directory / 'android-release-status.json').read_text())
            else:
                self.assertEqual((directory / 'android-release.p12').stat().st_mode & 0o777, 0o600)
                self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                self.assertFalse(any(directory.glob('.android-key-*')))
                self.assertNotIn(public_password, (directory / 'android-release.json').read_text())
            return commands

    def test_creates_protected_identity_without_secret_output_or_argv(self):
        self.exercise()

    def test_existing_keychain_identity_is_preserved(self):
        commands = self.exercise('existing')
        self.assertFalse(any('delete-generic-password' in argv for argv, _ in commands))

    def test_unverified_keychain_does_not_create_key(self):
        commands = self.exercise('verification')
        self.assertFalse(any('-genkeypair' in argv for argv, _ in commands))
        self.assertFalse(any('delete-generic-password' in argv for argv, _ in commands))

    def test_generation_failure_preserves_reference_for_review(self):
        commands = self.exercise('keytool')
        self.assertFalse(any('delete-generic-password' in argv for argv, _ in commands))

    def test_landed_key_without_receipt_has_partial_status(self):
        commands = self.exercise('receipt')
        self.assertFalse(any('delete-generic-password' in argv for argv, _ in commands))

    def test_unknown_or_replaced_reference_is_never_deleted(self):
        for failure in ('timeout', 'replacement', 'store-timeout', 'store-error'):
            with self.subTest(failure=failure):
                commands = self.exercise(failure)
                self.assertFalse(any('delete-generic-password' in argv for argv, _ in commands))

    def test_existing_keystore_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            directory = home / 'Library/Application Support/BettboxSigning'
            directory.mkdir(parents=True)
            target = directory / 'android-release.p12'
            target.write_bytes(b'EXISTING-KEY-FIXTURE')
            with patch.object(Path, 'home', return_value=home), patch.object(signing, 'command') as command, patch.object(sys, 'argv', ['fixture', '--execute']):
                with self.assertRaises(RuntimeError): signing.main()
                command.assert_not_called()
            self.assertEqual(target.read_bytes(), b'EXISTING-KEY-FIXTURE')


if __name__ == '__main__':
    unittest.main()
