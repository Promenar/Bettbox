"""固定生产打包边界的假工具回归测试；不会启动 helper 或调用工具链。"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_ROOT = Path(__file__).resolve().parents[1]
# 候选树和集成后的 scripts/tests 均使用项目现有公开 no-follow 工具。
CORE_PATH = SCRIPT_ROOT / "macos_core_identity.py"
if not CORE_PATH.exists():
    CORE_PATH = Path(__file__).resolve().parents[5] / "scripts/macos_core_identity.py"
for name, path in (("macos_core_identity", CORE_PATH),
                   ("macos_supervisor_artifact", SCRIPT_ROOT / "macos_supervisor_artifact.py")):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
artifact = sys.modules["macos_supervisor_artifact"]


class SupervisorArtifactTest(unittest.TestCase):
    def fixture(self, root):
        (root / artifact.EXECUTABLE.parent).mkdir(parents=True)
        for name in artifact.SOURCE_FILES:
            file = root / artifact.SOURCE_ROOT / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(("PUBLIC_SOURCE:" + name).encode())

    def output(self):
        return "Identifier=" + artifact.IDENTIFIER + "\nCDHash=" + "a" * 40 + "\nSignature=adhoc\nTeamIdentifier=not set"

    def runner(self, root, hook=None):
        def run(commands):
            results = []
            for argv in commands:
                if argv[0] == "/usr/bin/xcrun":
                    destination = root / argv[argv.index("-o") + 1]
                    destination.write_bytes(b"PUBLIC_COMPILED")
                    destination.chmod(0o700)
                if argv[1] == "--force":
                    helper = root / argv[-1]
                    replacement = helper.parent / "signed-replacement"
                    replacement.write_bytes(b"PUBLIC_SIGNED")
                    replacement.chmod(0o700)
                    replacement.replace(helper)
                value = self.output() if argv[1] == "--display" else None
                if hook:
                    value = hook(argv, value)
                results.append(value)
            return results
        return run

    def test_signed_replacement_inode_is_new_baseline_and_manifest_is_canonical(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            before = artifact.source_hashes(root)
            result = artifact.prepare_supervisor_artifact(root, self.runner(root))
            self.assertEqual(result["sha256"], hashlib.sha256(b"PUBLIC_SIGNED").hexdigest())
            self.assertEqual(artifact.read_identity(root)[0], result)
            self.assertEqual(set(result), {"schema", "sha256", "identifier", "cdhash", "signingmode"})
            self.assertEqual(artifact.source_hashes(root), before)
            stage = next((root / artifact.EXECUTABLE.parent).glob(".supervisor-build-*"))
            baseline = json.loads((stage / "SOURCE_BASE.json").read_text())
            final = json.loads((stage / "SOURCE_RESULT.json").read_text())
            self.assertEqual(baseline["source_hashes_before"], final["source_hashes_after"])

    def test_compile_contract_has_no_fixture_definitions_and_fixed_target(self):
        commands = artifact.compile_arguments(Path("PUBLIC_STAGE"), Path("PUBLIC_SOURCE"))
        self.assertEqual(len(commands), 3)
        for command in commands:
            self.assertEqual(command[command.index("-target") + 1], "arm64-apple-macos12")
            self.assertFalse(any("PUBLIC_FIXTURE" in argument for argument in command))
            self.assertNotIn("-D", command)
        swift = commands[-1]
        self.assertEqual(sum(argument.endswith(".swift") for argument in swift), 9)
        self.assertIn("PUBLIC_SOURCE/Relay/HelperC.h", swift)
        self.assertEqual(swift.count("-framework"), 2)
        self.assertIn("-lproc", swift)

    def test_wrong_core_identifier_and_duplicate_signature_never_publish(self):
        outputs = [self.output().replace(artifact.IDENTIFIER, "com.appshub.bettbox.core"),
                   self.output() + "\nCDHash=" + "a" * 40]
        for output in outputs:
            with self.subTest(output=output), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.fixture(root)
                runner = self.runner(root, lambda argv, value: output if argv[1] == "--display" else value)
                with self.assertRaises(RuntimeError):
                    artifact.prepare_supervisor_artifact(root, runner)
                self.assertFalse((root / artifact.IDENTITY_PATH).exists())
                self.assertFalse((root / artifact.EXECUTABLE).exists())

    def test_compilation_and_signing_failure_never_publish(self):
        for stage in ("clang", "--force", "--verify", "--display"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.fixture(root)
                def fail(argv, value):
                    if stage in argv:
                        raise RuntimeError("PUBLIC_TOOL_FAILURE")
                    return value
                with self.assertRaises(RuntimeError):
                    artifact.prepare_supervisor_artifact(root, self.runner(root, fail))
                self.assertFalse((root / artifact.IDENTITY_PATH).exists())
                self.assertFalse((root / artifact.EXECUTABLE).exists())

    def test_source_and_verification_digest_drift_rejected(self):
        for stage in ("clang", "--verify", "--display"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.fixture(root)
                def drift(argv, value):
                    if stage in argv:
                        path = root / (artifact.SOURCE_ROOT / "Bridge.h" if stage == "clang" else Path(argv[-1]))
                        path.write_bytes(b"PUBLIC_DRIFT")
                    return value
                with self.assertRaisesRegex(RuntimeError, "漂移"):
                    artifact.prepare_supervisor_artifact(root, self.runner(root, drift))
                self.assertFalse((root / artifact.IDENTITY_PATH).exists())
                self.assertFalse((root / artifact.EXECUTABLE).exists())

    def test_source_link_destination_link_fifo_and_parent_link_never_run(self):
        for kind in ("source", "destination", "manifest", "fifo", "parent"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.fixture(root)
                target = root / "public-target"
                target.write_bytes(b"PUBLIC")
                if kind == "source":
                    link = root / artifact.SOURCE_ROOT / "Bridge.h"
                    link.unlink()
                    link.symlink_to(target)
                elif kind in ("destination", "manifest"):
                    link = root / (artifact.EXECUTABLE if kind == "destination" else artifact.IDENTITY_PATH)
                    link.symlink_to(target)
                elif kind == "fifo":
                    os.mkfifo(root / artifact.EXECUTABLE)
                else:
                    parent = root / artifact.EXECUTABLE.parent
                    parent.rmdir()
                    parent.symlink_to(root)
                runner = mock.Mock()
                with self.assertRaises((OSError, RuntimeError)):
                    artifact.prepare_supervisor_artifact(root, runner)
                runner.assert_not_called()
                self.assertEqual(target.read_bytes(), b"PUBLIC")

    def test_manifest_commit_failure_removes_success_marker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            original = os.replace
            def fail_manifest(source, destination, **kwargs):
                if destination == artifact.IDENTITY_PATH.name:
                    raise OSError("PUBLIC_REPLACE_FAILURE")
                return original(source, destination, **kwargs)
            with mock.patch.object(artifact.os, "replace", side_effect=fail_manifest):
                with self.assertRaises(OSError):
                    artifact.prepare_supervisor_artifact(root, self.runner(root))
            self.assertFalse((root / artifact.IDENTITY_PATH).exists())

    def test_duplicate_json_or_noncanonical_manifest_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            manifest = root / artifact.IDENTITY_PATH
            manifest.write_bytes(b'{"schema":1,"schema":1}')
            with self.assertRaisesRegex(RuntimeError, "重复"):
                artifact.read_identity(root)
            value = artifact.parse_signature(self.output())
            value["sha256"] = "a" * 64
            manifest.write_text(json.dumps(value))
            with self.assertRaisesRegex(RuntimeError, "规范"):
                artifact.read_identity(root)

    def test_cli_redacts_failure_and_rejects_arbitrary_paths(self):
        with mock.patch.object(artifact, "prepare_supervisor_artifact", side_effect=RuntimeError("PUBLIC_SECRET")), \
                mock.patch("builtins.print") as output:
            self.assertEqual(artifact.main(["--prepare"]), 1)
        output.assert_called_once_with("macOS supervisor 产物准备失败")
        with self.assertRaises(SystemExit):
            artifact.main(["--prepare", "--root", "/PUBLIC_PATH"])

    def test_system_runner_uses_only_path_environment_and_suppresses_log(self):
        commands = artifact.signing_arguments(Path("PUBLIC_HELPER"))
        with mock.patch.object(artifact.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=self.output())) as run:
            artifact.run_commands(Path("PUBLIC_ROOT"), commands)
        self.assertEqual(run.call_count, 3)
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["env"], artifact.ENV)
            self.assertEqual(call.args[0][0], "/usr/bin/codesign")


if __name__ == "__main__":
    unittest.main()
