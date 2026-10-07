from __future__ import annotations

import importlib.util
import json
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
    def test_windows_reparse_point_rejected_before_file_open(self) -> None:
        info = mock.Mock(st_mode=0o100644, st_file_attributes=0x400)
        with mock.patch.object(validate_desktop.os, "supports_dir_fd", set()), \
                mock.patch.object(Path, "lstat", return_value=info), \
                mock.patch.object(validate_desktop.os, "open") as opened:
            with self.assertRaisesRegex(RuntimeError, "reparse point"):
                validate_desktop.source_file_hash(Path("repo"), "lib/input.dart")
        opened.assert_not_called()

    def test_windows_parent_change_during_read_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "lib").mkdir()
            (root / "lib/input.dart").write_text("fixture")
            with mock.patch.object(validate_desktop.os, "supports_dir_fd", set()), \
                    mock.patch.object(validate_desktop, "checked_source_parents", side_effect=[{"parent": (1,)}, {"parent": (2,)}]):
                with self.assertRaisesRegex(RuntimeError, "源码父路径"):
                    validate_desktop.source_file_hash(root, "lib/input.dart")

    def test_same_untracked_path_content_change_invalidates_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(("git", "init", "-q"), cwd=root, check=True)
            subprocess.run(("git", "-c", "user.name=构建测试", "-c", "user.email=fixture@example.invalid",
                            "commit", "--allow-empty", "-qm", "夹具"), cwd=root, check=True)
            (root / "lib").mkdir()
            source = root / "lib/new.dart"
            source.write_text("first")
            (root / ".video_agent").mkdir()
            (root / ".video_agent/private").write_text("不属于构建")
            before = validate_desktop.git_source_state(root)
            source.write_text("other")
            after = validate_desktop.git_source_state(root)
            self.assertEqual(before["status"], after["status"])
            self.assertEqual(before["tracked_diff_sha256"], after["tracked_diff_sha256"])
            self.assertNotEqual(before["source_sha256"], after["source_sha256"])
            self.assertEqual(before["source_file_count"], 1)

    def test_source_links_and_parent_links_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "lib").mkdir()
            (root / "outside").mkdir()
            (root / "outside/input.dart").write_text("fixture")
            (root / "lib/link.dart").symlink_to(root / "outside/input.dart")
            (root / "lib/parent").symlink_to(root / "outside", target_is_directory=True)
            for name in ("lib/link.dart", "lib/parent/input.dart"):
                with self.subTest(name=name), self.assertRaises((OSError, RuntimeError)):
                    validate_desktop.source_file_hash(root, name)

    def test_signing_material_is_excluded_before_open(self) -> None:
        with mock.patch.object(validate_desktop.os, "open") as opened:
            self.assertIsNone(validate_desktop.source_file_hash(Path("repo"), "macos/private.p12"))
            self.assertIsNone(validate_desktop.source_file_hash(Path("repo"), "plugins/.env"))
        opened.assert_not_called()

    def test_flutter_first_start_logs_do_not_replace_machine_version(self) -> None:
        machine = json.dumps({"frameworkVersion": "3.44.9", "dartSdkVersion": "3.12.2"})
        self.assertEqual(validate_desktop.parse_flutter_version(machine), "3.44.9")
        first_start = "Building flutter tool...\nRunning pub upgrade...\nResolving dependencies...\n" + machine
        self.assertEqual(validate_desktop.parse_flutter_version(first_start), "3.44.9")
        for invalid in ["Flutter 3.44.9", '{}', '{"frameworkVersion":null}', machine + machine]:
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                validate_desktop.parse_flutter_version(invalid)

    def test_batch_entry_is_resolved_without_losing_arguments(self) -> None:
        batch = r"C:\Program Files\Flutter\bin\flutter.bat"
        with mock.patch.object(validate_desktop.shutil, "which", return_value=batch):
            self.assertEqual(
                validate_desktop.executable_argv(("flutter", "--version", "--machine")),
                (batch, "--version", "--machine"),
            )

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

        self.assertEqual(len(plan), 9)
        self.assertEqual(plan[1].env["GOOS"], "darwin")
        self.assertEqual(plan[1].env["GOARCH"], "arm64")
        self.assertNotIn("GOAMD64", plan[1].env)
        self.assertEqual(
            validate_desktop.TARGETS["macos-arm64"].go_version_prefix, "1.26."
        )
        self.assertEqual(
            validate_desktop.TARGETS["macos-arm64"].bundled_core_path,
            Path(
                "build/macos/Build/Products/Release/Bettbox.app/Contents/MacOS/BettboxCore"
            ),
        )
        self.assertEqual(plan[5].argv, ("pod", "install", "--deployment"))
        self.assertEqual(plan[6].argv[2], "macos")
        self.assertEqual(plan[7].argv[:3], ("codesign", "--verify", "--deep"))
        self.assertTrue(plan[8].capture_output)

    def test_unsigned_macos_is_explicit_and_rejected_for_windows(self) -> None:
        plan = validate_desktop.command_plan(
            Path("repo"),
            validate_desktop.TARGETS["macos-arm64"],
            "digest",
            unsigned_macos=True,
        )
        self.assertEqual(len(plan), 8)
        self.assertEqual(
            plan[6].env, {"FLUTTER_XCODE_CODE_SIGNING_ALLOWED": "NO"}
        )
        self.assertEqual(plan[-1].argv[:2], ("codesign", "--display"))
        self.assertTrue(plan[-1].capture_output)
        self.assertFalse(plan[-1].check)
        self.assertEqual(
            validate_desktop.parse_unsigned_signature(
                "Signature=adhoc\nTeamIdentifier=not set\n"
                "Sealed Resources=none\nInfo.plist=not bound\nExecutable=/tmp/Bettbox"
            ),
            [
                "Signature=adhoc",
                "TeamIdentifier=not set",
                "Sealed Resources=none",
                "Info.plist=not bound",
            ],
        )
        self.assertEqual(
            validate_desktop.signing_mode(
                validate_desktop.TARGETS["macos-arm64"], True
            ),
            "unsigned",
        )
        with self.assertRaisesRegex(RuntimeError, "仅支持 macos-arm64"):
            validate_desktop.command_plan(
                Path("repo"),
                validate_desktop.TARGETS["windows-x64"],
                "digest",
                unsigned_macos=True,
            )

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

    def test_command_failure_records_lock_and_source_drift_without_masking(self) -> None:
        target = validate_desktop.TARGETS["windows-x64"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in validate_desktop.LOCK_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("locked", encoding="utf-8")

            before = {
                "head": "candidate",
                "dirty": False,
                "status": [],
                "tracked_diff_sha256": "before",
            }
            after = {
                "head": "candidate",
                "dirty": True,
                "status": [" M pubspec.lock"],
                "tracked_diff_sha256": "after",
            }
            failure = subprocess.CalledProcessError(9, ("flutter", "pub", "get"))

            def fail_and_change_lock(commands: object) -> None:
                del commands
                (root / validate_desktop.LOCK_FILES[0]).write_text(
                    "changed", encoding="utf-8"
                )
                raise failure

            with (
                mock.patch.object(
                    validate_desktop,
                    "git_source_state",
                    side_effect=[before, after],
                ),
                mock.patch.object(
                    validate_desktop,
                    "run_commands",
                    side_effect=fail_and_change_lock,
                ),
            ):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    validate_desktop.execute_build(root, target)

            self.assertIs(caught.exception, failure)
            self.assertIn("source_unchanged=False", failure.__notes__[0])
            self.assertIn("locks_unchanged=False", failure.__notes__[0])
            manifest_path = root / "build/desktop-validation/windows-x64.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertFalse(manifest["commands_succeeded"])
            self.assertEqual(
                manifest["requested_signing_mode"], "not-applicable"
            )
            self.assertFalse(manifest["source_unchanged"])
            self.assertFalse(manifest["locks_unchanged"])
            self.assertEqual(manifest["command_error"]["returncode"], 9)
            self.assertIn("pubspec.lock", manifest["changed_locks"])

    def test_validation_failure_is_closed_after_commands_succeed(self) -> None:
        target = validate_desktop.TARGETS["windows-x64"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in validate_desktop.LOCK_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("locked", encoding="utf-8")
            core = root / target.core_path
            core.parent.mkdir(parents=True, exist_ok=True)
            core.write_bytes(b"core")
            state = {
                "head": "candidate",
                "dirty": False,
                "status": [],
                "tracked_diff_sha256": "same",
            }
            validation_error = RuntimeError("bundle validation failed")

            with (
                mock.patch.object(
                    validate_desktop,
                    "git_source_state",
                    side_effect=[state, state, state],
                ),
                mock.patch.object(validate_desktop, "run_commands", return_value=[]),
                mock.patch.object(validate_desktop, "copy_windows_helper"),
                mock.patch.object(
                    validate_desktop,
                    "validate_bundle",
                    side_effect=validation_error,
                ),
            ):
                with self.assertRaises(RuntimeError) as caught:
                    validate_desktop.execute_build(root, target)

            self.assertIs(caught.exception, validation_error)
            manifest = json.loads(
                (
                    root / "build/desktop-validation/windows-x64.json"
                ).read_text(encoding="utf-8")
            )
            self.assertTrue(manifest["commands_succeeded"])
            self.assertEqual(
                manifest["command_error"]["message"], "bundle validation failed"
            )


    def core_signature_fixture(self) -> str:
        return ("Identifier=com.appshub.bettbox.core\nCDHash=" + "a" * 40 +
                "\nSignature=adhoc\nTeamIdentifier=not set")

    def test_core_identity_parser_rejects_wrong_or_duplicate_identity(self) -> None:
        valid = self.core_signature_fixture()
        self.assertEqual(validate_desktop.parse_core_signature(valid)["identifier"], validate_desktop.CORE_IDENTIFIER)
        for wrong in [valid.replace("com.appshub.bettbox.core", "a.out"),
                      valid + "\nCDHash=" + "b" * 40,
                      valid.replace("Signature=adhoc", "Signature=Developer ID"),
                      valid.replace("CDHash=" + "a" * 40, "CDHash=invalid")]:
            with self.assertRaises(RuntimeError):
                validate_desktop.parse_core_signature(wrong)

    def test_macos_signing_precedes_hash_binding_and_flutter_even_unsigned_host(self) -> None:
        target = validate_desktop.TARGETS["macos-arm64"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in validate_desktop.LOCK_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("locked")
            seen = []
            signed_hash = None
            def fake_run(commands):
                nonlocal signed_hash
                outputs = []
                for command in commands:
                    seen.append(command.argv)
                    if command.argv[0] == "go":
                        path = root / target.core_path
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(b"GO_PUBLIC_UNSIGNED")
                    if command.argv[:2] == ("codesign", "--force"):
                        (root / target.core_path).write_bytes(b"FINAL_PUBLIC_ADHOC_CORE")
                        signed_hash = validate_desktop.sha256_file(root / target.core_path)
                    if command.argv[:3] == ("flutter", "build", "macos"):
                        self.assertIsNotNone(signed_hash)
                        self.assertIn("--dart-define=CORE_SHA256=" + signed_hash, command.argv)
                        identity, source = validate_desktop.read_core_identity(root, validate_desktop.CORE_IDENTITY_PATH)
                        self.assertEqual(identity["sha256"], signed_hash)
                        for relative in (*target.app_paths, target.bundled_core_path):
                            path = root / relative
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.write_bytes(b"FINAL_PUBLIC_ADHOC_CORE" if relative == target.bundled_core_path else b"PUBLIC_APP")
                        manifest = root / target.bundle_path / "Contents/Resources/BettboxCoreIdentity.json"
                        manifest.parent.mkdir(parents=True, exist_ok=True)
                        manifest.write_bytes(source)
                    if command.capture_output:
                        outputs.append(self.core_signature_fixture() if command.argv[-1].endswith("BettboxCore") else "code object is not signed at all")
                    else:
                        outputs.append(None)
                return outputs
            def fake_codesign(argv, **kwargs):
                nonlocal signed_hash
                self.assertEqual(argv[0], "/usr/bin/codesign")
                self.assertEqual(kwargs["env"], {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
                self.assertEqual(kwargs["timeout"], 60)
                if argv[1] == "--force":
                    (root / target.core_path).write_bytes(b"FINAL_PUBLIC_ADHOC_CORE")
                    signed_hash = validate_desktop.sha256_file(root / target.core_path)
                seen.append(tuple(argv))
                return mock.Mock(stdout=self.core_signature_fixture())
            with mock.patch.object(validate_desktop, "git_source_state", return_value={"head": "PUBLIC_SAME"}), \
                    mock.patch.object(validate_desktop, "run_commands", side_effect=fake_run), \
                    mock.patch.object(validate_desktop.core_identity_module.subprocess, "run", side_effect=fake_codesign) as native_sign:
                validate_desktop.execute_build(root, target, unsigned_macos=True)
            self.assertLess(next(i for i, argv in enumerate(seen) if argv[:2] == ("/usr/bin/codesign", "--force")),
                            next(i for i, argv in enumerate(seen) if argv[:3] == ("flutter", "build", "macos")))
            self.assertEqual(native_sign.call_count, 5)
            receipt = json.loads((root / "build/desktop-validation/macos-arm64.json").read_text())
            self.assertEqual(receipt["host_signing_mode"], "unsigned")
            self.assertEqual(receipt["core_identity"]["signingmode"], "adhoc")
            self.assertEqual(receipt["core_identity"]["sha256"], signed_hash)

    def test_macos_manifest_tamper_and_packaging_resign_are_rejected(self) -> None:
        target = validate_desktop.TARGETS["macos-arm64"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (target.core_path, target.bundled_core_path, *target.app_paths):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"PUBLIC_CORE")
            identity = validate_desktop.parse_core_signature(self.core_signature_fixture())
            identity["sha256"] = validate_desktop.sha256_file(root / target.core_path)
            source = root / validate_desktop.CORE_IDENTITY_PATH
            bundle = root / target.bundle_path / "Contents/Resources/BettboxCoreIdentity.json"
            bundle.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(json.dumps(identity))
            bundle.write_bytes(source.read_bytes())
            with mock.patch.object(validate_desktop.core_identity_module, "run_identity_commands", return_value=[None, self.core_signature_fixture()]):
                validate_desktop.validate_bundle(root, target, identity)
                for field, bad in [("identifier", "a.out"), ("schema", True), ("signingmode", "DeveloperID"), ("cdhash", "b" * 40)]:
                    tampered = dict(identity, **{field: bad})
                    source.write_text(json.dumps(tampered))
                    bundle.write_bytes(source.read_bytes())
                    with self.assertRaises(RuntimeError):
                        validate_desktop.validate_bundle(root, target, identity)
                source.write_text(json.dumps(identity))
                bundle.write_bytes(source.read_bytes())
                (root / target.bundled_core_path).write_bytes(b"PACKAGING_RESIGNED_CORE")
                with self.assertRaisesRegex(RuntimeError, "core SHA256 不一致"):
                    validate_desktop.validate_bundle(root, target, identity)
            self.assertEqual(json.loads(source.read_text()), identity)

    def test_windows_stage_commands_keep_existing_order_and_no_signing(self) -> None:
        plan = validate_desktop.command_plan(Path("repo"), validate_desktop.TARGETS["windows-x64"], "PUBLIC_HASH")
        self.assertEqual([command.argv[0] for command in plan], ["flutter", "go", "cargo", "flutter"])
        self.assertEqual([command.stage for command in plan], ["prepare", "prepare", "dependencies", "flutter"])
        self.assertEqual(validate_desktop.commands_in_stage(plan, "core-sign"), [])
        self.assertEqual(plan[2].env, {"TOKEN": "PUBLIC_HASH"})

if __name__ == "__main__":
    unittest.main()
