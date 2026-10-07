"""公开产物漂移与异常清理回归，不启动真实子进程。"""

import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from scripts import check_macos_owned_process as subject


class OwnedProcessChecks(unittest.TestCase):
    def test_cleanup_continues_after_kill_wait_and_stream_errors(self):
        child = Mock()
        child.poll.return_value = None
        child.kill.side_effect = OSError()
        child.wait.side_effect = OSError()
        child.stdin.close.side_effect = OSError()
        with patch.object(subject.os, "close", side_effect=[OSError(), None]) as close:
            errors = subject.cleanup_owned(child, [101, 102])
        self.assertTrue(errors)
        child.wait.assert_called_once()
        child.stdout.close.assert_called_once()
        self.assertEqual([x.args[0] for x in close.call_args_list], [101, 102])

    def test_binary_byte_drift_fails_before_launch(self):
        with tempfile.TemporaryDirectory(dir=subject.ROOT / ".test") as directory:
            binary = Path(directory) / "fixture"
            binary.write_bytes(b"PUBLIC_ORIGINAL")
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            with patch.object(subject, "BINARY", binary):
                identity = subject.binary_identity(digest)
                binary.write_bytes(b"PUBLIC_CHANGED")
                with patch.object(subject.subprocess, "Popen") as launch:
                    result = subject.run_case("drift", "normal", digest, identity)
                launch.assert_not_called()
                self.assertFalse(result["passed"])
                self.assertFalse(result["binary_stable"])

    def test_same_bytes_replacement_fails_file_identity(self):
        with tempfile.TemporaryDirectory(dir=subject.ROOT / ".test") as directory:
            binary = Path(directory) / "fixture"
            binary.write_bytes(b"PUBLIC_ORIGINAL")
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            with patch.object(subject, "BINARY", binary):
                identity = subject.binary_identity(digest)
                replacement = Path(directory) / "replacement"
                replacement.write_bytes(b"PUBLIC_ORIGINAL")
                replacement.replace(binary)
                with patch.object(subject.subprocess, "Popen") as launch:
                    result = subject.run_case("replace", "normal", digest, identity)
                launch.assert_not_called()
                self.assertFalse(result["passed"])

    def test_failed_preflight_overwrites_old_passed_receipt(self):
        with tempfile.TemporaryDirectory(dir=subject.ROOT / ".test") as directory:
            receipt = Path(directory) / "receipt.json"
            receipt.write_text('{"status":"passed"}')
            with patch.object(subject, "RECEIPT", receipt), \
                 patch.object(subject, "binary_identity", side_effect=RuntimeError()), \
                 patch("sys.argv", ["fixture", "--expected-sha256", "0" * 64]):
                self.assertEqual(subject.main(), 1)
            self.assertIn('"status": "failed"', receipt.read_text())


if __name__ == "__main__":
    unittest.main()
