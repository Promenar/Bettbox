from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("macos_core_identity", Path(__file__).resolve().parents[1] / "macos_core_identity.py")
assert SPEC is not None and SPEC.loader is not None
identity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = identity
SPEC.loader.exec_module(identity)


class MacosCoreIdentityTest(unittest.TestCase):
    def output(self):
        return "Identifier=" + identity.CORE_IDENTIFIER + "\nCDHash=" + "a" * 40 + "\nSignature=adhoc\nTeamIdentifier=not set"

    def test_prepare_hashes_final_signed_bytes_and_only_public_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = root / identity.CORE_EXECUTABLE
            core.parent.mkdir(parents=True)
            core.write_bytes(b"PUBLIC_GO_CORE")
            calls = []
            def runner(arguments):
                calls.extend(arguments)
                if arguments[0][1] == "--force":
                    replacement = core.parent / "signed-replacement"
                    replacement.write_bytes(b"PUBLIC_FINAL_SIGNED_CORE")
                    replacement.replace(core)
                return [self.output() if argv[1] == "--display" else None for argv in arguments]
            result = identity.prepare_core_identity(root, runner)
            self.assertEqual(calls, identity.core_signing_arguments())
            self.assertEqual(result["sha256"], identity.stable_core_hash(root))
            self.assertEqual(set(result), {"schema", "sha256", "identifier", "cdhash", "signingmode"})
            self.assertEqual(json.loads((root / identity.CORE_IDENTITY_PATH).read_text()), result)

    def test_invalid_signature_never_hashes_or_publishes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = root / identity.CORE_EXECUTABLE
            core.parent.mkdir(parents=True)
            core.write_bytes(b"PUBLIC_CORE")
            with mock.patch.object(identity, "hash_bound_file") as digest:
                with self.assertRaises(RuntimeError):
                    identity.prepare_core_identity(root, lambda arguments: ["PUBLIC_BAD_DIAGNOSTIC" if argv[1] == "--display" else None for argv in arguments])
                digest.assert_not_called()
            self.assertFalse((root / identity.CORE_IDENTITY_PATH).exists())

    def test_sign_or_verify_failure_does_not_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = root / identity.CORE_EXECUTABLE
            core.parent.mkdir(parents=True)
            core.write_bytes(b"PUBLIC_CORE")
            def fail(arguments):
                raise RuntimeError("PUBLIC_COMMAND_FAILURE")
            with self.assertRaises(RuntimeError):
                identity.prepare_core_identity(root, fail)
            self.assertFalse((root / identity.CORE_IDENTITY_PATH).exists())

    def test_core_symlink_and_duplicate_json_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = root / identity.CORE_EXECUTABLE
            core.parent.mkdir(parents=True)
            public = core.parent / "public-fixture"
            public.write_bytes(b"PUBLIC")
            core.symlink_to(public)
            with self.assertRaises(OSError):
                identity.stable_core_hash(root)
            manifest = root / identity.CORE_IDENTITY_PATH
            manifest.write_text('{"schema":1,"schema":1}')
            with self.assertRaisesRegex(RuntimeError, "重复"):
                identity.read_core_identity(root, identity.CORE_IDENTITY_PATH)

    def test_prepare_static_links_and_special_files_never_call_runner(self):
        import os
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = root / identity.CORE_EXECUTABLE
            core.parent.mkdir(parents=True)
            public = root / "public-target"
            public.write_bytes(b"PUBLIC")
            for kind in ("link", "fifo"):
                if kind == "link":
                    core.symlink_to(public)
                else:
                    os.mkfifo(core)
                runner = mock.Mock()
                with self.assertRaises((OSError, RuntimeError)):
                    identity.prepare_core_identity(root, runner)
                runner.assert_not_called()
                core.unlink()
            parent = core.parent
            parent.rmdir()
            parent.symlink_to(root)
            runner = mock.Mock()
            with self.assertRaises(OSError):
                identity.prepare_core_identity(root, runner)
            runner.assert_not_called()

    def test_verify_or_display_inode_replacement_is_rejected(self):
        for stage in ("--verify", "--display"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                core = root / identity.CORE_EXECUTABLE
                core.parent.mkdir(parents=True)
                core.write_bytes(b"PUBLIC_ORIGINAL")
                def replace(argv, **kwargs):
                    if argv[1] == stage:
                        replacement = core.parent / "replacement"
                        replacement.write_bytes(b"PUBLIC_OTHER")
                        replacement.replace(core)
                    return mock.Mock(stdout=self.output())
                with mock.patch.object(identity.subprocess, "run", side_effect=replace):
                    with self.assertRaisesRegex(RuntimeError, "漂移"):
                        identity.prepare_core_identity(root)
                self.assertFalse((root / identity.CORE_IDENTITY_PATH).exists())

    def test_signing_phase_parent_replacement_is_rejected_before_verify(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = root / identity.CORE_EXECUTABLE
            core.parent.mkdir(parents=True)
            core.write_bytes(b"PUBLIC_ORIGINAL")
            def replace(arguments):
                core.parent.rename(root / "old-parent")
                core.parent.mkdir()
                core.write_bytes(b"PUBLIC_OTHER")
                return [None]
            runner = mock.Mock(side_effect=replace)
            with self.assertRaisesRegex(RuntimeError, "父目录身份"):
                identity.prepare_core_identity(root, runner)
            self.assertEqual(runner.call_count, 1)
            self.assertFalse((root / identity.CORE_IDENTITY_PATH).exists())

    def test_manifest_parent_swap_never_reads_replacement_target(self):
        import os
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            parent = (root / identity.CORE_IDENTITY_PATH).parent
            parent.mkdir(parents=True)
            original = b'{"schema":1}'
            (parent / identity.CORE_IDENTITY_PATH.name).write_bytes(original)
            outside = root / "public-outside"
            outside.mkdir()
            (outside / identity.CORE_IDENTITY_PATH.name).write_bytes(b"PUBLIC_MUST_NOT_READ")
            real_open, real_read = os.open, os.read
            swapped = False
            reads = []
            def swap_open(path, flags, *args, **kwargs):
                nonlocal swapped
                if path == identity.CORE_IDENTITY_PATH.name and not swapped:
                    swapped = True
                    parent.rename(root / "original-held-directory")
                    parent.symlink_to(outside)
                return real_open(path, flags, *args, **kwargs)
            def record_read(fd, size):
                value = real_read(fd, size)
                reads.append(value)
                return value
            with mock.patch.object(identity.os, "open", side_effect=swap_open), \
                    mock.patch.object(identity.os, "read", side_effect=record_read):
                with self.assertRaises((OSError, RuntimeError)):
                    identity.read_core_identity(root, identity.CORE_IDENTITY_PATH)
            self.assertEqual(reads, [original])

    def test_cli_failure_output_does_not_expose_diagnostic(self):
        with mock.patch.object(identity, "prepare_core_identity", side_effect=RuntimeError("PUBLIC_MUST_NOT_ESCAPE")), \
                mock.patch("builtins.print") as output:
            self.assertEqual(identity.main(["--prepare"]), 1)
        output.assert_called_once_with("macOS core 身份准备失败")

    def test_timeout_from_dedicated_runner_never_publishes_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            core = root / identity.CORE_EXECUTABLE
            core.parent.mkdir(parents=True)
            core.write_bytes(b"PUBLIC_CORE")
            for failed_step in range(3):
                responses = [mock.Mock(stdout=self.output()) for _ in range(failed_step)]
                responses.append(identity.subprocess.TimeoutExpired("/usr/bin/codesign", 60, output="PUBLIC_DIAGNOSTIC"))
                with mock.patch.object(identity.subprocess, "run", side_effect=responses) as runner:
                    with self.assertRaises(identity.subprocess.TimeoutExpired):
                        identity.prepare_core_identity(root)
                self.assertEqual(runner.call_count, failed_step + 1)
                self.assertFalse((root / identity.CORE_IDENTITY_PATH).exists())

    def test_default_runner_uses_only_system_codesign_and_clean_environment(self):
        with mock.patch.object(identity.subprocess, "run", return_value=mock.Mock(stdout=self.output())) as run:
            identity.run_identity_commands(Path("PUBLIC_ROOT"), identity.core_signing_arguments())
        self.assertEqual(run.call_count, 3)
        for call in run.call_args_list:
            self.assertEqual(call.args[0][0], "/usr/bin/codesign")
            self.assertEqual(call.kwargs["env"], {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
            self.assertEqual(call.kwargs["timeout"], 60)


if __name__ == "__main__":
    unittest.main()
