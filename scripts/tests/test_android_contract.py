"""Android 扩展必须保持已批准的主机、目标与入口。"""
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "android_contract", Path(__file__).parents[1] / "validate_android_contract.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AndroidContractTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/build_android.py").write_text("# 测试入口\n")
        self.contract = {
            "targets": {"local-mac": {"os": "macos", "arch": "arm64"}},
            "platform_extensions": {"android": {
                "executor": "local-mac", "target_os": "android",
                "target_arch": "arm64", "cwd": ".",
                "argv": ["python3", "scripts/build_android.py", "--execute"],
                "artifacts": ["build/app/outputs/flutter-apk/app-debug.apk"],
                "timeout_seconds": 2700,
            }},
        }

    def test_approved_android_target_is_preserved(self):
        self.assertEqual(module.validate_android(self.root, self.contract)["target_os"], "android")

    def test_modified_platform_host_or_command_is_rejected(self):
        for key, value in [("target_os", "linux"), ("target_arch", "x86_64"),
                           ("executor", "other"), ("cwd", ".."),
                           ("argv", ["sh", "-c", "unapproved"]),
                           ("artifacts", ["../outside"]),
                           ("timeout_seconds", True), ("timeout_seconds", 2701)]:
            with self.subTest(key=key):
                mutated = copy.deepcopy(self.contract)
                mutated["platform_extensions"]["android"][key] = value
                with self.assertRaises(ValueError):
                    module.validate_android(self.root, mutated)
        self.contract["targets"]["local-mac"]["os"] = "linux"
        with self.assertRaises(ValueError):
            module.validate_android(self.root, self.contract)

    def test_missing_or_symlink_entry_is_rejected(self):
        script = self.root / "scripts/build_android.py"
        script.unlink()
        with self.assertRaises(ValueError):
            module.validate_android(self.root, self.contract)
        script.symlink_to(self.root / "outside.py")
        with self.assertRaises(ValueError):
            module.validate_android(self.root, self.contract)

    def release_operation(self):
        return {**self.contract['platform_extensions']['android'],
                'argv': ['python3', 'scripts/build_android.py', '--execute', '--release'],
                'artifacts': ['build/app/outputs/flutter-apk/app-release.apk']}

    def test_missing_release_only_blocks_release(self):
        module.validate_android(self.root, self.contract)
        with self.assertRaises(ValueError):
            module.validate_android_release(self.root, self.contract)
        self.contract['platform_extensions']['android_release'] = self.release_operation()
        self.assertEqual(module.validate_android_release(self.root, self.contract), self.release_operation())
        module.validate_android(self.root, self.contract)

    def test_release_exact_command_artifact_budget_and_host(self):
        operation = self.release_operation()
        self.contract['platform_extensions']['android_release'] = operation
        for key, value in [('argv', operation['argv'][:-1]), ('artifacts', ['build/app/outputs/flutter-apk/app-debug.apk']),
                           ('timeout_seconds', 2699), ('timeout_seconds', True), ('executor', 'other'),
                           ('target_os', 'linux'), ('target_arch', 'x86_64'), ('cwd', '..')]:
            with self.subTest(key=key):
                contract = copy.deepcopy(self.contract)
                contract['platform_extensions']['android_release'][key] = value
                with self.assertRaises(ValueError):
                    module.validate_android_release(self.root, contract)
        self.contract['targets']['local-mac']['arch'] = 'x86_64'
        with self.assertRaises(ValueError):
            module.validate_android_release(self.root, self.contract)

    def test_release_does_not_require_debug_extension_but_rejects_symlink(self):
        operation = self.release_operation()
        self.contract['platform_extensions'] = {'android_release': operation}
        module.validate_android_release(self.root, self.contract)
        entry = self.root / 'scripts/build_android.py'
        entry.unlink(); entry.symlink_to(self.root / 'outside.py')
        with self.assertRaises(ValueError):
            module.validate_android_release(self.root, self.contract)

    def test_main_release_returns_release_operation_only(self):
        self.contract['platform_extensions']['android_release'] = self.release_operation()
        (self.root / '.pdec').mkdir()
        (self.root / '.pdec/contract.yaml').write_text(json.dumps(self.contract))
        framework = {'execution_ready': True, 'contract_digest': 'a' * 64}
        for release in (False, True):
            with self.subTest(release=release), mock.patch.object(module, '__file__', str(self.root / 'scripts/validate_android_contract.py')), \
                    mock.patch.object(module.sys, 'argv', ['validator', '--framework-validator', '/public/fake'] + (['--release'] if release else [])), \
                    mock.patch.object(module.subprocess, 'run', return_value=mock.Mock(stdout=json.dumps(framework))) as runner, \
                    mock.patch('sys.stdout', new_callable=io.StringIO) as output:
                self.assertEqual(module.main(), 0)
                result = json.loads(output.getvalue())
                key = 'release_operation' if release else 'android_operation'
                self.assertIn(key, result)
                self.assertNotIn('android_operation' if release else 'release_operation', result)
                self.assertNotIn('--release', runner.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
