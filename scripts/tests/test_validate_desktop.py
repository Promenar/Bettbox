from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "validate_desktop.py"
SPEC = importlib.util.spec_from_file_location("validate_desktop", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
validate_desktop = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = validate_desktop
SPEC.loader.exec_module(validate_desktop)


class ValidateDesktopTest(unittest.TestCase):
    def test_windows_plan_uses_readonly_core_and_locked_helper(self) -> None:
        root = Path("repo")
        plan = validate_desktop.command_plan(
            root,
            validate_desktop.TARGETS["windows-x64"],
            "abc123",
        )

        go_command = plan[1]
        self.assertIn("-mod=readonly", go_command.argv)
        self.assertIn("-tags=with_gvisor", go_command.argv)
        self.assertEqual(go_command.env["CGO_ENABLED"], "0")
        self.assertEqual(go_command.env["GOAMD64"], "v1")
        self.assertEqual(
            validate_desktop.TARGETS["windows-x64"].go_version_prefix, "1.25."
        )

        cargo_command = plan[2]
        self.assertIn("--locked", cargo_command.argv)
        self.assertEqual(cargo_command.env["TOKEN"], "abc123")

        flutter_command = plan[3]
        self.assertIn("--dart-define=CORE_SHA256=abc123", flutter_command.argv)
        self.assertFalse(any("build_runner" in command.argv for command in plan))

    def test_macos_plan_is_arm64_native_without_windows_helper(self) -> None:
        plan = validate_desktop.command_plan(
            Path("repo"),
            validate_desktop.TARGETS["macos-arm64"],
            "digest",
        )

        self.assertEqual(len(plan), 6)
        self.assertEqual(plan[1].env["GOOS"], "darwin")
        self.assertEqual(plan[1].env["GOARCH"], "arm64")
        self.assertNotIn("GOAMD64", plan[1].env)
        self.assertEqual(
            validate_desktop.TARGETS["macos-arm64"].go_version_prefix, "1.26."
        )
        self.assertEqual(plan[2].argv, ("pod", "install", "--deployment"))
        self.assertEqual(plan[3].argv[2], "macos")
        self.assertEqual(plan[4].argv[:3], ("codesign", "--verify", "--deep"))
        self.assertTrue(plan[5].capture_output)

    def test_host_validation_rejects_wrong_platform_or_architecture(self) -> None:
        target = validate_desktop.TARGETS["windows-x64"]
        with self.assertRaisesRegex(RuntimeError, "必须在 Windows/x86_64 原生执行"):
            validate_desktop.validate_host(target, "Darwin", "arm64")

    def test_command_failure_stops_following_commands(self) -> None:
        commands = [
            validate_desktop.Command(("first",), Path("."), label="first"),
            validate_desktop.Command(("second",), Path("."), label="second"),
        ]
        failure = subprocess.CalledProcessError(7, ("first",))
        with mock.patch.object(
            validate_desktop.subprocess,
            "run",
            side_effect=[failure],
        ) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                validate_desktop.run_commands(commands)
        self.assertEqual(run.call_count, 1)

    def test_lock_snapshot_detects_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in validate_desktop.LOCK_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("locked", encoding="utf-8")
            before = validate_desktop.snapshot_locks(root)
            (root / validate_desktop.LOCK_FILES[0]).write_text(
                "changed", encoding="utf-8"
            )
            with self.assertRaisesRegex(RuntimeError, "锁文件发生变化"):
                validate_desktop.assert_locks_unchanged(root, before)

    def test_display_redacts_helper_token(self) -> None:
        command = validate_desktop.Command(
            ("cargo", "build"),
            Path("repo/services/helper"),
            env={"TOKEN": "actual-hash"},
        )
        rendered = validate_desktop.display_command(command, Path("repo"))
        self.assertIn("TOKEN=<core-sha256>", rendered)
        self.assertNotIn("actual-hash", rendered)

    def test_bundle_requires_current_core_and_helper_hashes(self) -> None:
        target = validate_desktop.TARGETS["windows-x64"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                target.core_path: b"core",
                Path("libclash/windows/BettboxHelperService.exe"): b"helper",
                Path("build/windows/x64/runner/Release/Bettbox.exe"): b"app",
                target.bundled_core_path: b"core",
                target.bundled_helper_path: b"helper",
                Path("build/windows/x64/runner/Release/data/flutter_assets/AssetManifest.bin"): b"index",
            }
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            sources, bundle_files, bindings = validate_desktop.validate_bundle(
                root, target
            )
            self.assertEqual(len(sources), 2)
            self.assertGreaterEqual(len(bundle_files), 4)
            self.assertEqual(len(bindings), 2)

            (root / target.bundled_core_path).write_bytes(b"stale-core")
            with self.assertRaisesRegex(RuntimeError, "core SHA256 不一致"):
                validate_desktop.validate_bundle(root, target)

    def test_adhoc_signature_requires_no_team(self) -> None:
        evidence = validate_desktop.parse_adhoc_signature(
            "Executable=/tmp/Bettbox\nSignature=adhoc\nTeamIdentifier=not set\n"
        )
        self.assertEqual(evidence, ["Signature=adhoc", "TeamIdentifier=not set"])
        with self.assertRaisesRegex(RuntimeError, "不是无 Team"):
            validate_desktop.parse_adhoc_signature(
                "Signature=adhoc\nTeamIdentifier=TEAM123\n"
            )

    def test_source_state_must_match_exactly(self) -> None:
        before = {
            "head": "abc",
            "dirty": True,
            "status": [" M lib/state.g.dart"],
            "tracked_diff_sha256": "one",
        }
        self.assertTrue(validate_desktop.source_state_unchanged(before, dict(before)))
        after = dict(before)
        after["tracked_diff_sha256"] = "two"
        self.assertFalse(validate_desktop.source_state_unchanged(before, after))


if __name__ == "__main__":
    unittest.main()
