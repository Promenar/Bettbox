"""只使用公开 fixture 和 mock 工具，禁止读取真实钥匙串或生成密钥。"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('release_signing', Path(__file__).resolve().parents[1] / 'android_release_signing.py')
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)
PUBLIC_PASSWORD = b'a' * 64


class ReleaseSigningTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.directory = self.home / 'Library/Application Support/BettboxSigning'
        self.directory.mkdir(parents=True, mode=0o700)
        self.target = self.directory / 'android-release.p12'
        self.keychain = self.home / 'Library/Keychains/login.keychain-db'
        self.keychain.parent.mkdir(parents=True)
        for path in (self.target, self.keychain):
            path.write_bytes(b'PUBLIC_UNUSED_FILE')
            path.chmod(0o600)
        self.receipt = self.directory / 'android-release.json'
        self.identity = {'status': 'created', 'keystore': str(self.target), 'alias': signing.ALIAS,
                         'keychain_service': signing.SERVICE, 'keychain_account': signing.ACCOUNT,
                         'keychain_path': str(self.keychain), 'certificate_sha256': signing.CERTIFICATE_SHA256,
                         'created_at': '2026-10-07T00:00:00Z', 'password_logged': False}
        self.save_identity()
        self.sdk = self.home / 'sdk'
        self.tool = self.sdk / 'build-tools/36.0.0/apksigner'
        self.tool.parent.mkdir(parents=True)
        self.tool.write_bytes(b'PUBLIC_NOT_EXECUTED')
        self.tool.chmod(0o700)
        self.apk = self.home / 'public.apk'
        self.apk.write_bytes(b'PUBLIC_APK_NOT_EXECUTED')
        self.env = {'ANDROID_SDK_ROOT': str(self.sdk), 'JAVA_HOME': '/public/jdk'}
        self.patch = mock.patch.object(signing.Path, 'home', return_value=self.home)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def save_identity(self):
        self.receipt.write_text(json.dumps(self.identity))
        self.receipt.chmod(0o600)

    def test_only_environment_receives_password_and_fixed_command_reads_login_chain(self):
        with mock.patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, PUBLIC_PASSWORD + b'\n', b'PUBLIC_ERROR')) as run:
            env = signing.signing_environment({'PATH': '/public/bin', 'BETTBOX_ANDROID_KEY_ALIAS': 'untrusted'})
        self.assertEqual(env['BETTBOX_ANDROID_STORE_PASSWORD'], PUBLIC_PASSWORD.decode())
        self.assertEqual(env['BETTBOX_ANDROID_KEY_PASSWORD'], PUBLIC_PASSWORD.decode())
        self.assertEqual(env['BETTBOX_ANDROID_KEY_ALIAS'], signing.ALIAS)
        self.assertEqual(run.call_args.args[0], ['/usr/bin/security', 'find-generic-password', '-s', signing.SERVICE, '-a', signing.ACCOUNT, '-w', str(self.keychain)])
        self.assertNotIn(PUBLIC_PASSWORD.decode(), str(run.call_args))
        self.assertNotIn('BETTBOX_ANDROID_STORE_PASSWORD', run.call_args.kwargs['env'])

    def test_identity_tampering_never_reads_credentials(self):
        mutations = {'alias': 'androiddebugkey', 'keystore': '/outside/identity.p12', 'keychain_service': 'other',
                     'keychain_account': 'other', 'keychain_path': '/outside/login.keychain-db',
                     'certificate_sha256': '0' * 64, 'status': 'partial-requires-review', 'password_logged': True}
        original = dict(self.identity)
        for key, value in mutations.items():
            with self.subTest(key=key):
                self.identity = {**original, key: value}
                self.save_identity()
                with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
                    signing.signing_environment({})
                run.assert_not_called()

    def test_private_permissions_and_parent_or_file_links_are_rejected(self):
        for path, permissive in [(self.directory, 0o755), (self.receipt, 0o644), (self.target, 0o644), (self.keychain, 0o644)]:
            original = path.stat().st_mode & 0o777
            path.chmod(permissive)
            with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
                signing.signing_environment({})
            run.assert_not_called()
            path.chmod(original)
        moved = self.target.with_suffix('.saved')
        self.target.rename(moved)
        self.target.symlink_to(moved)
        with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
            signing.signing_environment({})
        run.assert_not_called()
        self.target.unlink()
        moved.rename(self.target)
        folder = self.directory.with_name('PUBLIC_REAL')
        self.directory.rename(folder)
        self.directory.symlink_to(folder, target_is_directory=True)
        with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
            signing.signing_environment({})
        run.assert_not_called()

    def test_tool_failures_never_expose_password_or_original_diagnostic(self):
        for outcome in [subprocess.CompletedProcess([], 1, PUBLIC_PASSWORD, b'PUBLIC_DIAGNOSTIC'),
                        subprocess.CompletedProcess([], 0, b'PUBLIC_DIAGNOSTIC', b''),
                        subprocess.TimeoutExpired('PUBLIC_DIAGNOSTIC', 30, output=PUBLIC_PASSWORD)]:
            with self.subTest(kind=type(outcome).__name__), mock.patch.object(signing.subprocess, 'run') as run:
                if isinstance(outcome, Exception): run.side_effect = outcome
                else: run.return_value = outcome
                with self.assertRaises(signing.SigningFailure) as caught:
                    signing.signing_environment({})
                self.assertEqual(str(caught.exception), '正式签名环境不可用')
                self.assertNotIn(PUBLIC_PASSWORD.decode(), str(caught.exception))
                self.assertIsNone(caught.exception.__cause__)

    def test_verification_has_no_password_and_returns_only_public_evidence(self):
        output = ('Signer #1 certificate SHA-256 digest: ' + signing.CERTIFICATE_SHA256 + '\n').encode()
        env = {**self.env, 'BETTBOX_ANDROID_STORE_PASSWORD': PUBLIC_PASSWORD.decode(), 'BETTBOX_ANDROID_KEY_PASSWORD': PUBLIC_PASSWORD.decode()}
        with mock.patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, b'')) as run:
            result = signing.verify_signed_apk(self.apk, env)
        self.assertEqual(result, {'verified': True, 'certificate_sha256': signing.CERTIFICATE_SHA256, 'signers': 1})
        self.assertEqual(run.call_args.args[0], [str(self.tool), 'verify', '--print-certs', str(self.apk)])
        self.assertNotIn(PUBLIC_PASSWORD.decode(), str(run.call_args))
        self.assertNotIn(PUBLIC_PASSWORD.decode(), json.dumps(result))

    def test_debug_multiple_signers_invalid_and_tool_failure_are_rejected(self):
        valid = 'Signer #1 certificate SHA-256 digest: ' + signing.CERTIFICATE_SHA256 + '\n'
        outputs = [('Signer #1 certificate SHA-256 digest: ' + '0' * 64 + '\n', 0),
                   (valid + 'Signer #2 certificate SHA-256 digest: ' + signing.CERTIFICATE_SHA256 + '\n', 0),
                   ('PUBLIC_DIAGNOSTIC', 0), (valid, 1)]
        for output, code in outputs:
            with self.subTest(code=code), mock.patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, output.encode(), b'PUBLIC_DIAGNOSTIC')):
                with self.assertRaisesRegex(signing.SigningFailure, '^正式 APK 验签失败$'):
                    signing.verify_signed_apk(self.apk, self.env)

    def test_input_replacement_after_tool_call_is_rejected(self):
        def changed(*args, **kwargs):
            self.apk.write_bytes(b'PUBLIC_CHANGED')
            return subprocess.CompletedProcess([], 0, ('Signer #1 certificate SHA-256 digest: ' + signing.CERTIFICATE_SHA256 + '\n').encode(), b'')
        with mock.patch.object(signing.subprocess, 'run', side_effect=changed), self.assertRaises(signing.SigningFailure):
            signing.verify_signed_apk(self.apk, self.env)

    def test_credential_reference_replacement_before_environment_return_is_rejected(self):
        def changed(*args, **kwargs):
            self.target.write_bytes(b'PUBLIC_REPLACED_KEYSTORE')
            return subprocess.CompletedProcess([], 0, PUBLIC_PASSWORD, b'')
        with mock.patch.object(signing.subprocess, 'run', side_effect=changed), self.assertRaisesRegex(signing.SigningFailure, '^正式签名环境不可用$'):
            signing.signing_environment({})

    def test_sdk_scope_tool_permissions_and_apk_links_fail_before_tool(self):
        envs = [{}, {'ANDROID_SDK_ROOT': 'relative'},
                {**self.env, 'ANDROID_HOME': '/public/other-sdk'}]
        for env in envs:
            with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
                signing.verify_signed_apk(self.apk, env)
            run.assert_not_called()
        self.tool.chmod(0o777)
        with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
            signing.verify_signed_apk(self.apk, self.env)
        run.assert_not_called()
        self.tool.chmod(0o700)
        real = self.apk.with_suffix('.saved')
        self.apk.rename(real)
        self.apk.symlink_to(real)
        with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
            signing.verify_signed_apk(self.apk, self.env)
        run.assert_not_called()

    def test_receipt_duplicate_fields_and_extra_command_are_rejected(self):
        for raw in ['{"status":"created","status":"created"}', json.dumps({**self.identity, 'credential_command': ['/public/unknown']})]:
            self.receipt.write_text(raw)
            with mock.patch.object(signing.subprocess, 'run') as run, self.assertRaises(signing.SigningFailure):
                signing.signing_environment({})
            run.assert_not_called()

    def test_receipt_replaced_during_json_parse_never_reads_credentials(self):
        original_loads = signing.json.loads
        def replaced(*args, **kwargs):
            value = original_loads(*args, **kwargs)
            replacement = self.receipt.with_suffix('.replacement')
            replacement.write_text(json.dumps(self.identity))
            replacement.chmod(0o600)
            os.replace(replacement, self.receipt)
            return value
        with mock.patch.object(signing.json, 'loads', side_effect=replaced), \
                mock.patch.object(signing.subprocess, 'run') as run, \
                self.assertRaisesRegex(signing.SigningFailure, '^正式签名环境不可用$'):
            signing.signing_environment({})
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
