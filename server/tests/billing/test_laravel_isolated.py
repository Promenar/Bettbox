"""隔离 runner 的纯 mock 边界测试；不调用 SSH、PHP、Docker 或业务数据库。"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('laravel_isolated', Path(__file__).with_name('run_laravel_isolated.py'))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
TASK = '1' * 32
CHECKS = ['negative_checkout_no_gateway_and_review_committed', 'real_open_and_traffic_reset',
          'repeat_commission_once', 'cancel_refund_once', 'outbox_at_least_once_consumer_idempotent',
          'historical_negative_processing_no_open', 'fubei_open_and_event_once', 'fixture_work_removed']
CHECKS += ['migration_actual_class', 'migration_history_preserved', 'migration_empty_down_preserves_history',
           'migration_up_after_empty_down', 'migration_foreign_keys_valid', 'migration_same_isolated_connection',
           'migration_evidence_attempt_retained', 'migration_evidence_review_retained',
           'migration_evidence_outbox_retained', 'migration_evidence_commission_retained',
           'migration_collision_order_id', 'migration_collision_level']
CHECKS += ['migration_collision_' + name for name in ['v2_billing_mutex','v2_payment_attempt','v2_billing_review','v2_billing_outbox']]
CHECKS += ['migration_unexpected_RuntimeException_propagated', 'migration_unexpected_UnexpectedValueException_propagated',
           'migration_migrator_exact_path', 'migration_migrator_batch_recorded',
           'migration_migrator_repeat_noop', 'migration_migrator_rollback_history_preserved',
           'migration_migrator_failure_atomic', 'migration_migrator_down_failure_atomic']
CHECKS += ['migration_repository_insert_failure_atomic','migration_repository_delete_failure_atomic',
           'migration_command_plan_no_write','migration_command_failure_fixed_and_atomic',
           'migration_command_real_rollback','migration_command_real_up','migration_command_repeat_noop',
           'migration_command_foreign_batch_retained','migration_command_financial_evidence_retained']


class LaravelIsolatedTest(unittest.TestCase):
    def test_real_migration_input_and_completion_are_required(self):
        self.assertIn('server/patches/billing/overlay/database/migrations/2026_10_07_000001_add_billing_atomicity.php', runner.CANDIDATE_INPUTS)
        hashes = {'candidate/server/tests/billing/laravel_check.php': 'a' * 64}
        payload = {'ok': True, 'checks': [x for x in CHECKS if not x.startswith('migration_')], 'source_hashes': {},
                   'environment_loaded': False, 'production_database_loaded': False}
        with self.assertRaises(runner.RunnerFailure):
            runner.result_summary(json.dumps(payload).encode(), hashes)

    def exercise(self, failure=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            public = root / '.test/billing-laravel-public-source'
            for base, names in [(root, runner.CANDIDATE_INPUTS), (public, runner.PUBLIC_INPUTS)]:
                for name in names:
                    path = base / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'PUBLIC_FIXTURE')
            (public / '.env').write_text('PUBLIC_EXTRA_MUST_NOT_UPLOAD')
            (public / 'public-source-receipt.json').write_text('{}')
            commands, uploads = [], []
            _, hashes, _ = runner.freeze(root, public)
            reported = {'/fixture/source/' + name: digest for name, digest in hashes.items()}
            reported.pop('/fixture/source/candidate/server/tests/billing/laravel_check.php')
            payload = {'ok': True, 'checks': CHECKS, 'source_hashes': reported,
                       'environment_loaded': False, 'production_database_loaded': False}
            if failure == 'evidence':
                payload['source_hashes'][next(iter(reported))] = '0' * 64
            if failure == 'contract':
                payload['checks'] = CHECKS[:-1]
            if failure == 'missing':
                (root / runner.CANDIDATE_INPUTS[0]).unlink()

            def fake_ssh(command, **kwargs):
                commands.append(command)
                output = b''
                if 'docker inspect' in command:
                    output = ('sha256:' + 'a' * 64 + '\n').encode()
                    if failure == 'image':
                        output = b'not-an-image-digest'
                elif 'tar -xf' in command:
                    uploads.append(kwargs['data'])
                elif '240s' in command:
                    if failure == 'timeout':
                        raise subprocess.TimeoutExpired('PUBLIC_COMMAND', 265, stderr=b'RAW_SERVER_BODY')
                    if failure == 'vendor':
                        raise subprocess.CalledProcessError(1, 'PUBLIC_COMMAND', output=b'{"ok":false,"stage":"root_vendor-root"}', stderr=b'RAW_SERVER_BODY')
                    if failure == 'raw':
                        output = b'RAW_SERVER_BODY'
                    else:
                        output = json.dumps(payload).encode()
                    if failure == 'source':
                        (root / runner.CANDIDATE_INPUTS[0]).write_text('PUBLIC_CHANGED')
                    if failure == 'parent_link':
                        directory = public / 'app/Models'
                        directory.rename(public / 'app/ModelCopy')
                        directory.symlink_to(public / 'app/ModelCopy', target_is_directory=True)
                elif 'docker container ls' in command:
                    if failure == 'daemon':
                        raise subprocess.CalledProcessError(1, 'PUBLIC_COMMAND', stderr=b'RAW_SERVER_BODY')
                    if '.Label' in command:
                        output = ('bettbox-laravel-' + TASK + (' other-owner' if failure == 'ownership' else ' ' + TASK)).encode()
                    elif failure == 'container':
                        output = b'leftover'
                elif command.startswith('( test') and failure == 'directory':
                    raise subprocess.CalledProcessError(1, 'PUBLIC_COMMAND', stderr=b'RAW_SERVER_BODY')
                return subprocess.CompletedProcess([], 0, stdout=output, stderr=b'RAW_SERVER_BODY')

            with patch.object(runner, 'ssh', fake_ssh), patch.object(runner.uuid, 'uuid4') as identifier:
                identifier.return_value.hex = TASK
                receipt = runner.execute(root, public)
            stored = json.loads((root / '.test/three-platform-release' / ('billing-laravel-receipt-' + TASK + '.json')).read_text())
            self.assertEqual(stored, receipt)
            self.assertNotIn('RAW_SERVER_BODY', json.dumps(receipt))
            if uploads:
                with tarfile.open(fileobj=io.BytesIO(uploads[0])) as archive:
                    expected = {'public/' + name for name in runner.PUBLIC_INPUTS} | {'candidate/' + name for name in runner.CANDIDATE_INPUTS}
                    self.assertEqual(set(archive.getnames()), expected)
                    self.assertTrue(all(member.isfile() and member.mode == 0o444 for member in archive))
            return receipt, commands

    def test_plan_does_not_read_write_or_contact_host(self):
        with patch.object(runner, 'freeze') as freeze, patch.object(runner, 'ssh') as ssh, patch.object(runner, 'write_receipt') as write, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main([]), 0)
        freeze.assert_not_called()
        ssh.assert_not_called()
        write.assert_not_called()

    def test_success_requires_frozen_exact_inputs_and_cleanup(self):
        receipt, commands = self.exercise()
        self.assertEqual(receipt['status'], 'passed')
        self.assertTrue(receipt['source_unchanged'])
        self.assertTrue(receipt['cleanup_verified'])
        self.assertEqual(len(receipt['source_hashes']), 55)
        command = next(command for command in commands if '240s' in command)
        for restriction in ['--network none', '--read-only', '--memory 128m', '--memory-swap 128m', '--cpus 0.5', '--pids-limit 64', '--cap-drop ALL', '--security-opt no-new-privileges', 'BETTBOX_VERIFY_ISOLATED_CONTAINER=1', '--vendor-root=/www/vendor']:
            self.assertIn(restriction, command)
        self.assertNotIn('source=/www', command)
        self.assertEqual(command.count('--mount'), 2)
        self.assertIn('target=/fixture/source,readonly', command)

    def test_failed_paths_always_write_failed_receipt(self):
        for failure in ['image', 'timeout', 'vendor', 'raw', 'evidence', 'contract', 'source', 'parent_link']:
            with self.subTest(failure=failure):
                receipt, _ = self.exercise(failure)
                self.assertEqual(receipt['status'], 'failed')
                self.assertTrue(receipt['cleanup_verified'])
                if failure == 'vendor':
                    self.assertEqual(receipt['fixture_failure_stage'], 'root_vendor-root')

    def test_missing_input_never_contacts_host(self):
        receipt, commands = self.exercise('missing')
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(commands, [])
        self.assertEqual(receipt['source_hashes'], {})

    def test_cleanup_requires_successful_directory_and_container_queries(self):
        for failure in ['daemon', 'directory', 'container', 'ownership']:
            with self.subTest(failure=failure):
                receipt, commands = self.exercise(failure)
                self.assertEqual(receipt['status'], 'failed')
                self.assertFalse(receipt['cleanup_verified'])
                if failure == 'ownership':
                    self.assertFalse(any('docker rm' in command or 'rm -rf' in command for command in commands))

    def test_linked_parent_and_file_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'real').mkdir()
            (root / 'real/file').write_text('PUBLIC_FIXTURE')
            (root / 'link').symlink_to(root / 'real', target_is_directory=True)
            (root / 'file-link').symlink_to(root / 'real/file')
            for path in [root / 'link/file', root / 'file-link']:
                with self.assertRaises(OSError):
                    runner.read_public(path)
            self.assertEqual(runner.read_public(root / 'real/file'), b'PUBLIC_FIXTURE')

    def test_receipt_directory_replacement_cannot_redirect_write(self):
        for component in ['.test', 'three-platform-release']:
            with self.subTest(component=component), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                folder = root / '.test/three-platform-release'
                folder.mkdir(parents=True)
                outside = root / 'outside'
                outside.mkdir()
                replaced = root / '.test' if component == '.test' else folder
                saved = root / 'saved-directory'
                real_open = runner.os.open
                swapped = False

                def replace_after_open(path, flags, mode=0o777, *, dir_fd=None):
                    nonlocal swapped
                    descriptor = real_open(path, flags, mode, dir_fd=dir_fd)
                    if path == component and dir_fd is not None and not swapped:
                        swapped = True
                        replaced.rename(saved)
                        replaced.symlink_to(outside, target_is_directory=True)
                    return descriptor

                receipt = {'status': 'failed', 'stage': 'PUBLIC_FIXTURE'}
                with patch.object(runner.os, 'open', replace_after_open):
                    runner.write_receipt(root, TASK, receipt)
                self.assertTrue(swapped)
                self.assertEqual(list(outside.iterdir()), [])
                destination = saved / 'three-platform-release' if component == '.test' else saved
                stored = destination / ('billing-laravel-receipt-' + TASK + '.json')
                self.assertEqual(json.loads(stored.read_text()), receipt)

    def test_receipt_existing_parent_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            outside = root / 'outside'
            outside.mkdir()
            (root / '.test').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(OSError):
                runner.write_receipt(root, TASK, {'status': 'failed'})
            self.assertEqual(list(outside.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
