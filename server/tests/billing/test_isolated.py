"""验证隔离执行器的失败回执；所有 SSH 和业务执行均使用虚构响应。"""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('billing_isolated', Path(__file__).with_name('run_isolated.py'))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class IsolatedReceiptTest(unittest.TestCase):
    def exercise(self, failure=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / 'server/tests/billing/run_isolated.py'
            for name in runner.PUBLIC_INPUTS:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('公开虚构 fixture')
            def fake_ssh(command, **kwargs):
                if 'inspect --format' in command:
                    output = ('sha256:' + 'a' * 64 + '\n').encode()
                elif 'docker container ls' in command:
                    if failure == 'daemon':
                        raise subprocess.CalledProcessError(1, '模拟 Docker 查询失败')
                    output = b'leftover\n' if failure == 'container' else b''
                elif command.startswith('test ! -e') and failure == 'directory':
                    raise subprocess.CalledProcessError(1, '模拟临时目录残留')
                elif '240s' in command:
                    if failure == 'source':
                        path = root / runner.PUBLIC_INPUTS[0]
                        path.write_text('执行期间变更')
                    output = b'fixture passed\n'
                else:
                    output = b''
                return subprocess.CompletedProcess([], 0, stdout=output, stderr=b'')
            with patch.object(runner, '__file__', str(script)), patch.object(runner, 'ssh', fake_ssh), patch.object(sys, 'argv', ['fixture', '--execute']), contextlib.redirect_stdout(io.StringIO()):
                if failure:
                    with self.assertRaises((RuntimeError, ValueError)):
                        runner.main()
                else:
                    runner.main()
            import json
            return json.loads((root / '.test/three-platform-release/billing-receipt.json').read_text())

    def test_pass_requires_source_and_both_cleanup_checks(self):
        receipt = self.exercise()
        self.assertEqual(receipt['status'], 'passed')
        self.assertTrue(receipt['source_unchanged'])
        self.assertTrue(receipt['cleanup_verified'])
        self.assertEqual(set(receipt['source_hashes']), set(runner.PUBLIC_INPUTS))

    def test_cleanup_failure_never_becomes_passed(self):
        for failure in ('daemon', 'container', 'directory'):
            with self.subTest(failure=failure):
                receipt = self.exercise(failure)
                self.assertEqual(receipt['status'], 'failed')
                self.assertFalse(receipt['cleanup_verified'])

    def test_source_change_rejects_successful_fixture(self):
        receipt = self.exercise('source')
        self.assertEqual(receipt['status'], 'failed')
        self.assertFalse(receipt['source_unchanged'])
        self.assertTrue(receipt['cleanup_verified'])

    def test_parent_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'real').mkdir()
            (root / 'real/file').write_text('公开 fixture')
            (root / 'link').symlink_to(root / 'real', target_is_directory=True)
            self.assertFalse(runner.safe_file(root / 'link/file', root))
            self.assertTrue(runner.safe_file(root / 'real/file', root))


if __name__ == '__main__':
    unittest.main()
