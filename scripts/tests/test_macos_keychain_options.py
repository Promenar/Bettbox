"""合成键诊断的输出边界和失败责任回归，不调用真实Keychain。"""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import probe_macos_keychain_options as probe


class ProbeBoundaryTests(unittest.TestCase):
    def report(self):
        return {"new_key_absent": True, "sync_query_status": -25300,
                "first_write_status": 0, "first_read_matches": True,
                "overwrite_status": 0, "overwrite_read_matches": True,
                "sync_delete_status": -34018, "local_delete_status": 0,
                "absent_after_delete": True, "repeat_delete_status": -25300,
                "plugin_delete_status": 0, "plugin_repeat_delete_status": -34018,
                "real_credentials_accessed": False,
                "scope": "独立合成键的原生查询行为；不代表完整Flutter插件或App验收"}

    def run_case(self, report=None, raw=None, timeout=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / ".test/macos-keychain-options").mkdir(parents=True)
            calls = []
            def run(argv, **kwargs):
                calls.append(argv)
                if len(calls) == 4:
                    if timeout:
                        raise subprocess.TimeoutExpired(argv, 60)
                    payload = raw if raw is not None else json.dumps(report).encode()
                    return subprocess.CompletedProcess(argv, 0, payload, b"PUBLIC_TOOL_ERROR_SENTINEL")
                return subprocess.CompletedProcess(argv, 0, b"", b"PUBLIC_TOOL_ERROR_SENTINEL")
            output = io.StringIO()
            with patch.object(probe, "ROOT", root), \
                 patch.object(probe.seal, "development_identity", return_value=("f" * 40, "PUBLIC_TEAM", "PUBLIC_IDENTITY")), \
                 patch.object(probe.subprocess, "run", side_effect=run), contextlib.redirect_stdout(output):
                code = probe.main()
            cases = list((root / ".test/macos-keychain-options").glob("*/case.json"))
            return code, output.getvalue(), len(cases), calls

    def test_diagnostic_preserves_repeat_delete_error(self):
        code, output, _, _ = self.run_case(self.report())
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output)["plugin_repeat_delete_status"], -34018)
        self.assertNotIn("PUBLIC_TOOL_ERROR_SENTINEL", output)
        self.assertNotIn("PUBLIC_IDENTITY", output)

    def test_unconfirmed_cleanup_fails(self):
        report = self.report(); report["absent_after_delete"] = False
        code, _, cases, _ = self.run_case(report)
        self.assertEqual(code, 1)
        self.assertEqual(cases, 1)

    def test_timeout_retains_case_and_reports_cleanup_pending(self):
        code, output, cases, _ = self.run_case(timeout=True)
        self.assertEqual(code, 1)
        self.assertTrue(json.loads(output)["synthetic_cleanup_pending"])
        self.assertEqual(cases, 1)

    def test_malformed_json_not_echoed(self):
        code, output, _, _ = self.run_case(raw=b"PUBLIC_UNTRUSTED_PAYLOAD")
        self.assertEqual(code, 1)
        self.assertNotIn("PUBLIC_UNTRUSTED_PAYLOAD", output)
        self.assertTrue(json.loads(output)["synthetic_cleanup_pending"])

    def test_unexpected_value_not_echoed(self):
        report = self.report(); report["overwrite_status"] = "PUBLIC_UNTRUSTED_PAYLOAD"
        code, output, _, _ = self.run_case(report)
        self.assertEqual(code, 1)
        self.assertNotIn("PUBLIC_UNTRUSTED_PAYLOAD", output)

    def test_unknown_field_rejected(self):
        report = self.report(); report["unknown"] = "PUBLIC_UNTRUSTED_PAYLOAD"
        code, output, _, _ = self.run_case(report)
        self.assertEqual(code, 1)
        self.assertNotIn("PUBLIC_UNTRUSTED_PAYLOAD", output)


if __name__ == "__main__":
    unittest.main()
