"""检查验证器的执行边界与来源绑定。"""
import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location('supervisor_check', Path(__file__).resolve().parents[1] / 'check_macos_supervisor.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SupervisorCheckTests(unittest.TestCase):
    def test_production_c_syntax_does_not_enable_public_fixture(self):
        steps = MODULE.commands(Path('/source'), Path('/work'), '/sdk')
        self.assertNotIn('-DOWNED_PUBLIC_FIXTURE', steps[0][1])
        self.assertIn('-DOWNED_PUBLIC_FIXTURE', steps[1][1])

    def test_fixture_flag_reaches_swift_and_c_header_importer(self):
        steps = dict(MODULE.commands(Path('/source'), Path('/work'), '/sdk'))
        for name in ('owner-fake-compile', 'owner-process-compile'):
            argv = steps[name]
            self.assertEqual(argv[argv.index('-D') + 1], 'OWNED_PUBLIC_FIXTURE')
            self.assertEqual(argv[argv.index('-Xcc') + 1], '-DOWNED_PUBLIC_FIXTURE')

    def test_identity_binary_never_includes_owner_stub(self):
        steps = dict(MODULE.commands(Path('/source'), Path('/work'), '/sdk'))
        argv = steps['identity-compile']
        self.assertFalse(any('OWNED_PUBLIC_FIXTURE' in value or 'SystemBackend' in value for value in argv))
        self.assertEqual(steps['identity-run'], ['/work/identity-fixtures'])

    def test_production_helper_links_only_production_owner_and_actual_identity(self):
        steps = dict(MODULE.commands(Path('/source'), Path('/work'), '/sdk'))
        argv = steps['production-helper-compile']
        self.assertFalse(any('OWNED_PUBLIC_FIXTURE' in value or 'FakeRuntime' in value for value in argv))
        self.assertIn('/work/production-owner.o', argv)
        self.assertNotIn('/work/backend.o', argv)
        self.assertIn('/source/macos/CoreSupervisor/Identity/SSIAppleBackend.swift', argv)
        self.assertNotIn('-DOWNED_PUBLIC_FIXTURE', steps['production-owner-c-object'])

    def test_backpressure_and_late_sdk_faults_are_registered(self):
        steps = dict(MODULE.commands(Path('/source'), Path('/work'), '/sdk'))
        for name in ('relay-fullpipe-close', 'relay-late-core', 'relay-half-result', 'kernel-run'):
            self.assertIn(name, steps)

    def test_hashes_reject_symlink_and_bind_actual_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in MODULE.SOURCE_NAMES:
                file = root / 'macos/CoreSupervisor' / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b'public fixture')
            before = MODULE.hashes(root)
            file = root / 'macos/CoreSupervisor' / MODULE.SOURCE_NAMES[0]
            file.write_bytes(b'changed fixture')
            self.assertNotEqual(before, MODULE.hashes(root))
            file.unlink()
            file.symlink_to(root / 'macos/CoreSupervisor' / MODULE.SOURCE_NAMES[1])
            with self.assertRaises(ValueError):
                MODULE.hashes(root)


if __name__ == '__main__':
    unittest.main()
