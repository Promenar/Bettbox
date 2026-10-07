"""直接调用actual run_case，以真实公开stdout pipe测试分类；不证明native身份。"""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fixture_runner", HERE / "runner.py")
runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
REAL_POPEN = subprocess.Popen
class PublicParserTests(unittest.TestCase):
    def actual(self, data, status):
        def child(*args, **kwargs):
            return REAL_POPEN([sys.executable, "-c", "import os; os.write(1," + repr(data) + "); raise SystemExit(" + str(status) + ")"], **kwargs)
        with patch.object(runner.subprocess, "Popen", side_effect=child):
            return runner.run_case(HERE / "Bettbox")["classification"]
    def test_positive_exact(self): self.assertEqual(self.actual(runner.POSITIVE, 0), "ACCEPTED")
    def test_negative_exact(self): self.assertEqual(self.actual(b"FIXTURE_REJECTED\n", 70), "REJECTED")
    def test_duplicate_negative(self): self.assertEqual(self.actual(b"FIXTURE_REJECTED\n"*2, 70), "EXECUTION_FAILED")
    def test_trailing_partial(self): self.assertEqual(self.actual(b"FIXTURE_REJECTED\nTRAILING", 70), "EXECUTION_FAILED")
    def test_wrong_exit(self): self.assertEqual(self.actual(b"FIXTURE_REJECTED\n", 0), "EXECUTION_FAILED")
    def test_fake_nativegone(self): self.assertEqual(self.actual(b"STOP0_NATIVE_GONE\nFIXTURE_OK\n", 0), "EXECUTION_FAILED")
if __name__ == "__main__": unittest.main()
