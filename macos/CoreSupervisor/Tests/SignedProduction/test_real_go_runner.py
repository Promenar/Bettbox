"""拒绝未绑定或被替换的Core时，不创建执行目录或启动签名工具。"""
import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location("real_go_fixture", HERE / "real_go_runner.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class CoreAdmissionTests(unittest.TestCase):
    def reject(self, digest, symlink=False):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            parent = root / ".test/three-platform-release"; parent.mkdir(parents=True)
            source = parent / "source"; source.write_bytes(b"public-core")
            core = parent / "core-owned-process"
            if symlink: core.symlink_to(source)
            else: core.write_bytes(source.read_bytes())
            with patch.object(fixture.runner, "REPO", root), \
                 patch.object(sys, "argv", ["fixture", "--expected-core-sha256", digest]), \
                 patch.object(fixture.runner, "build") as build:
                with self.assertRaises(fixture.runner.FixedFailure): fixture.main()
                build.assert_not_called()
            self.assertFalse((parent / "macos-supervisor-real-go").exists())

    def test_invalid_hash(self): self.reject("not-a-sha256")
    def test_replaced_core(self): self.reject("0" * 64)
    def test_symlink_even_with_matching_bytes(self):
        self.reject(hashlib.sha256(b"public-core").hexdigest(), symlink=True)


if __name__ == "__main__": unittest.main()
