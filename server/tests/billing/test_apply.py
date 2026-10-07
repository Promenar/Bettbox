#!/usr/bin/env python3
"""补丁安全边界验收，仅操作 TemporaryDirectory 内的一次性文件。"""
import hashlib
import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'patches/billing/apply.py'
spec = importlib.util.spec_from_file_location('billing_candidate_apply', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ApplySafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='billing-apply-')
        self.base = Path(self.temp.name).resolve()
        self.target = self.base / 'target'
        self.bundle = self.base / 'bundle'
        (self.target / 'app').mkdir(parents=True)
        (self.bundle / 'overlay/app').mkdir(parents=True)
        (self.target / 'app/source.php').write_bytes(b'original-public-fixture')
        (self.bundle / 'overlay/app/source.php').write_bytes(b'verified-candidate')
        (self.bundle / 'overlay/app/new.php').write_bytes(b'new-public-fixture')
        manifest = {'sources': {'app/source.php': self.hash(b'original-public-fixture')}, 'overlays': {'app/source.php': self.hash(b'verified-candidate'), 'app/new.php': self.hash(b'new-public-fixture')}}
        (self.bundle / 'manifest.json').write_text(json.dumps(manifest))

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def hash(value):
        return hashlib.sha256(value).hexdigest()

    def prepare(self):
        return module.Prepared(self.target, self.bundle)

    def test_verified_overlay_bytes_are_frozen(self):
        prepared = self.prepare()
        (self.bundle / 'overlay/app/source.php').write_bytes(b'changed-after-validation')
        (self.bundle / 'overlay/app/new.php').unlink()
        prepared.apply()
        self.assertEqual((self.target / 'app/source.php').read_bytes(), b'verified-candidate')
        self.assertEqual((self.target / 'app/new.php').read_bytes(), b'new-public-fixture')

    def test_new_destination_creation_is_rejected(self):
        prepared = self.prepare()
        (self.target / 'app/new.php').write_bytes(b'other-writer')
        with self.assertRaises(RuntimeError): prepared.apply()
        self.assertEqual((self.target / 'app/source.php').read_bytes(), b'original-public-fixture')

    def test_original_deletion_is_rejected(self):
        prepared = self.prepare()
        (self.target / 'app/source.php').unlink()
        with self.assertRaises(RuntimeError): prepared.apply()
        self.assertFalse((self.target / 'app/new.php').exists())

    def test_symlink_parent_is_rejected(self):
        prepared = self.prepare()
        (self.target / 'app').rename(self.target / 'parked')
        outside = self.base / 'outside'; outside.mkdir()
        (outside / 'source.php').write_bytes(b'outside-public-fixture')
        (self.target / 'app').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError): prepared.apply()
        self.assertEqual((outside / 'source.php').read_bytes(), b'outside-public-fixture')
        self.assertFalse((outside / 'new.php').exists())

    def test_rollback_rechecks_symlink_parent(self):
        prepared = self.prepare()
        real_write = prepared.target.write
        outside = self.base / 'outside'; outside.mkdir()
        (outside / 'source.php').write_bytes(b'outside-public-fixture')
        def fail_after_first(relative, data, expected, mode=0o644, committed=None):
            if relative == 'app/new.php':
                (self.target / 'app').rename(self.target / 'parked')
                (self.target / 'app').symlink_to(outside, target_is_directory=True)
                raise RuntimeError('公开第二文件故障')
            return real_write(relative, data, expected, mode, committed)
        prepared.target.write = fail_after_first
        with self.assertRaisesRegex(RuntimeError, '安全回滚拒绝'): prepared.apply()
        self.assertEqual((outside / 'source.php').read_bytes(), b'outside-public-fixture')
        self.assertFalse((outside / 'new.php').exists())
        self.assertEqual((self.target / 'parked/source.php').read_bytes(), b'verified-candidate')
        backup = next((self.target / '.billing-patch-backups').glob('*/app/source.php'))
        self.assertEqual(backup.read_bytes(), b'original-public-fixture')

    def test_regular_failure_rolls_back_from_frozen_original(self):
        prepared = self.prepare()
        real_write = prepared.target.write
        def fail_new(relative, data, expected, mode=0o644, committed=None):
            if relative == 'app/new.php': raise RuntimeError('公开写入失败')
            return real_write(relative, data, expected, mode, committed)
        prepared.target.write = fail_new
        with self.assertRaises(RuntimeError): prepared.apply()
        self.assertEqual((self.target / 'app/source.php').read_bytes(), b'original-public-fixture')
        self.assertFalse((self.target / 'app/new.php').exists())

    def test_failure_after_replace_or_link_includes_current_file_in_rollback(self):
        for filename in ['source.php','new.php']:
            for operation in ['fsync','stat']:
                with self.subTest(filename=filename,operation=operation):
                    prepared=self.prepare()
                    real_write=prepared.target.write
                    armed={'value':False,'failed':False}
                    def track_commit(relative,data,expected,mode=0o644,committed=None):
                        def registered(state):
                            if committed: committed(state)
                            if relative=='app/'+filename: armed['value']=True
                        return real_write(relative,data,expected,mode,registered)
                    prepared.target.write=track_commit
                    real_fsync=module.os.fsync
                    real_stat=module.os.stat
                    def failing_fsync(fd):
                        if armed['value'] and not armed['failed']:
                            armed['failed']=True
                            raise OSError('公开提交后fsync故障')
                        return real_fsync(fd)
                    def failing_stat(path,*args,**kwargs):
                        if path==filename and armed['value'] and not armed['failed']:
                            armed['failed']=True
                            raise OSError('公开提交后stat故障')
                        return real_stat(path,*args,**kwargs)
                    with mock.patch.object(module.os,operation,failing_fsync if operation=='fsync' else failing_stat):
                        with self.assertRaises(OSError): prepared.apply()
                    self.assertTrue(armed['failed'])
                    self.assertEqual((self.target/'app/source.php').read_bytes(),b'original-public-fixture')
                    self.assertFalse((self.target/'app/new.php').exists())


if __name__ == '__main__':
    unittest.main()
