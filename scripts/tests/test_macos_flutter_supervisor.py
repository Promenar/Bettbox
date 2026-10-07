"""公开探针终态必须同时满足完整协议和实际宿主退出。"""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_macos_flutter_supervisor import MARKERS, PROBE_INPUTS, MarkerReader, probe_hashes


class MarkerTests(unittest.TestCase):
    def feed(self, lines):
        reader = MarkerReader()
        data = ("\n".join(lines) + "\n").encode()
        for index in range(0, len(data), 7):
            reader.add(data[index:index + 7])
        return reader

    def test_fragmented_success_requires_exit(self):
        reader = self.feed(["公开引擎输出", *MARKERS])
        self.assertEqual(reader.classification(0), "ACCEPTED")
        self.assertEqual(reader.classification(None), "OWNER_RETAINED_UNKNOWN")
        self.assertEqual(reader.classification(70), "EXECUTION_FAILED")

    def test_duplicate_out_of_order_and_terminal_after_pass(self):
        for lines in ([MARKERS[0], MARKERS[0]], [MARKERS[1]],
                      [*MARKERS, "BETTBOX_PROBE_FAIL_CLEAN"],
                      ["BETTBOX_PROBE_FAIL_CLEAN", MARKERS[0]]):
            self.assertEqual(self.feed(lines).classification(70), "PROTOCOL_FAILED")

    def test_clean_failure_is_distinct_from_success(self):
        reader = self.feed([MARKERS[0], "BETTBOX_PROBE_FAIL_CLEAN"])
        self.assertEqual(reader.classification(70), "CLEAN_FAILED")
        self.assertEqual(reader.classification(0), "EXECUTION_FAILED")

    def test_unknown_payload_is_not_retained(self):
        reader = self.feed(["BETTBOX_PROBE_public-unexpected-value"])
        self.assertEqual(reader.markers, ["INVALID_MARKER"])
        self.assertEqual(reader.classification(0), "PROTOCOL_FAILED")

    def test_unterminated_or_oversized_marker_rejected(self):
        for data in (b"BETTBOX_PROBE_PASS", b"BETTBOX_PROBE_" + b"x" * 1024 + b"\n"):
            reader = MarkerReader(); reader.add(data)
            self.assertEqual(reader.classification(0), "PROTOCOL_FAILED")

    def test_noise_storage_bounded_and_output_limit_rejected(self):
        reader = self.feed(["x" * 4096, *MARKERS])
        self.assertEqual(reader.classification(0), "ACCEPTED")
        reader.add(b"x" * 131073)
        self.assertEqual(reader.classification(0), "PROTOCOL_FAILED")
        self.assertLessEqual(len(reader.buffer), 1024)


class SourceTests(unittest.TestCase):
    def fixture(self, root):
        for name in PROBE_INPUTS:
            path = root / name; path.parent.mkdir(exist_ok=True)
            path.write_text("公开未跟踪输入")

    def test_untracked_content_change_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root)
            before = probe_hashes(root)
            (root / PROBE_INPUTS[0]).write_text("变化的公开输入")
            self.assertNotEqual(before, probe_hashes(root))

    def test_probe_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root)
            file = root / PROBE_INPUTS[0]; file.unlink()
            file.symlink_to(root / PROBE_INPUTS[1])
            with self.assertRaises(OSError): probe_hashes(root)


if __name__ == "__main__": unittest.main()
