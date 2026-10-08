"""使用公开输入验证协议探针进程的完整收尾。"""
import datetime
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('probe', Path(__file__).parents[1] / 'probe_node_subscription.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class ProbeProcessTests(unittest.TestCase):
    def test_serialization_failure_does_not_start_process(self):
        with mock.patch.object(probe.subprocess, 'Popen') as launch:
            with self.assertRaises(TypeError):
                probe.run_probe(Path('/unused'), [{'date': datetime.date(2026, 10, 8)}])
            launch.assert_not_called()

    def check_cleanup(self, fail_communication):
        original = subprocess.Popen
        owned = []
        def launch(*args, **kwargs):
            process = original([sys.executable, '-c', 'import time; time.sleep(60)'], **kwargs)
            owned.append(process)
            if fail_communication:
                communicate = process.communicate
                process.communicate = mock.Mock(side_effect=[RuntimeError('公开测试异常'), mock.DEFAULT], wraps=communicate)
            return process
        try:
            with mock.patch.object(probe.subprocess, 'Popen', side_effect=launch):
                with self.assertRaises(RuntimeError if fail_communication else subprocess.TimeoutExpired):
                    probe.run_probe(Path('/unused'), [{}], timeout=0.02)
            self.assertIsNotNone(owned[0].poll())
            self.assertTrue(all(pipe.closed for pipe in (owned[0].stdin, owned[0].stdout, owned[0].stderr)))
        finally:
            for process in owned:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_non_timeout_exception_reaps_real_child(self):
        self.check_cleanup(True)

    def test_timeout_reaps_real_child(self):
        self.check_cleanup(False)

if __name__ == '__main__':
    unittest.main()
