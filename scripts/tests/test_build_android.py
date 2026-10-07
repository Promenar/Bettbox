from __future__ import annotations

import importlib.util
import json
import os
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "build_android.py"
SPEC = importlib.util.spec_from_file_location("build_android", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
android = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = android
SPEC.loader.exec_module(android)


def elf(*, align: int = 16384, machine: int = 183, offset: int = 0) -> bytes:
    data = bytearray(120)
    data[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", data, 18, machine)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HH", data, 54, 56, 1)
    struct.pack_into("<I", data, 64, 1)
    struct.pack_into("<QQ", data, 72, offset, 0)
    struct.pack_into("<Q", data, 112, align)
    return bytes(data)


class BuildAndroidTest(unittest.TestCase):
    def setUp(self) -> None:
        self.lease_patch = mock.patch.object(android.dependency_network, "NetworkLease")
        self.lease = self.lease_patch.start().return_value
        self.lease.proxy_port = 12345
        self.lease.close.return_value = True
        self.lease.history = []
        self.addCleanup(self.lease_patch.stop)

    def environment(self) -> dict[str, str]:
        return {"BETTBOX_GO": "/tools/go", "BETTBOX_FLUTTER": "/tools/flutter",
                "BETTBOX_CC": "/ndk/aarch64-linux-android26-clang",
                "BETTBOX_ZIPALIGN": "/sdk/zipalign", "GOWORK": "off", "JAVA_HOME": "/jdk"}

    def create_locks(self, root: Path) -> None:
        for name in android.LOCK_FILES:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("依赖固定\n")
        (root / "android").mkdir(exist_ok=True)
        (root / "android/gradle.properties").write_text("org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1g\n")
        wrapper = root / "android/gradle/wrapper/gradle-wrapper.properties"
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        wrapper.write_text("distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-all.zip\n")

    def apk(self, path: Path, *, wrong_abi: bool = False, missing: bool = False) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        abi = "x86_64" if wrong_abi else android.ABI
        with zipfile.ZipFile(path, "w") as archive:
            for name in ("libclash.so", "libcore.so", "libflutter.so"):
                if missing and name == "libclash.so":
                    continue
                archive.writestr(f"lib/{abi}/{name}", elf())

    def test_plan_uses_readonly_core_and_debug_without_signing_changes(self) -> None:
        plan = android.command_plan(Path("/repo"), self.environment(), Path("/stage"))
        core = plan[0]
        self.assertIn("-mod=readonly", core.argv)
        self.assertIn("-tags=with_gvisor", core.argv)
        self.assertIn("-buildmode=c-shared", core.argv)
        self.assertTrue(any("max-page-size=16384" in arg for arg in core.argv))
        self.assertEqual(core.env["GOOS"], "android")
        self.assertEqual(core.env["GOARCH"], "arm64")
        self.assertEqual(core.env["CGO_ENABLED"], "1")
        self.assertEqual(core.argv[-1], "/stage/libclash.so")
        self.assertIn("--enforce-lockfile", plan[1].argv)
        self.assertIn("--debug", plan[2].argv)
        self.assertEqual(plan[2].argv[-2:], ("--target-platform", "android-arm64"))
        self.assertFalse(any("tidy" in cmd.argv or "--release" in cmd.argv for cmd in plan))

    def test_environment_excludes_credentials_and_build_override_flags(self) -> None:
        with mock.patch.dict(os.environ, {"PATH": "/tools", "HOME": "/home",
                "AUTH_TOKEN": "hidden", "GOFLAGS": "-mod=mod", "KEY_PASSWORD": "hidden"}, clear=True):
            env = android.build_environment()
        self.assertEqual(env["PATH"], "/tools")
        self.assertNotIn("AUTH_TOKEN", env)
        self.assertNotIn("KEY_PASSWORD", env)
        self.assertNotIn("GOFLAGS", env)
        self.assertEqual(env["GOTOOLCHAIN"], "local")

    def test_elf_rejects_wrong_arch_alignment_and_corrupt_header(self) -> None:
        android.verify_elf(elf(), "核心")
        for data in (elf(align=4096), elf(machine=62), elf(offset=1), elf()[:100], b"bad"):
            with self.subTest(data=data[:10]), self.assertRaises(RuntimeError):
                android.verify_elf(data, "核心")

    def test_apk_checks_all_native_libraries_and_required_core(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "app.apk"
            self.apk(path)
            self.assertEqual(len(android.verify_apk(path)), 3)
            for kwargs in ({"wrong_abi": True}, {"missing": True}):
                self.apk(path, **kwargs)
                with self.assertRaises(RuntimeError):
                    android.verify_apk(path)

    def test_execution_records_verified_hashes_and_unchanged_locks(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.create_locks(root)
            homes = []

            def fake_run(argv, cwd, env, **kwargs):
                homes.append(env["GRADLE_USER_HOME"])
                self.assertIn("-Dorg.gradle.daemon=false", env["GRADLE_OPTS"])
                self.assertIn("-Djdk.net.hosts.file=", env["GRADLE_OPTS"])
                for protocol in ('http', 'https'):
                    self.assertIn(f'-D{protocol}.proxyHost=127.0.0.1', env['GRADLE_OPTS'])
                    self.assertIn(f'-D{protocol}.proxyPort=12345', env['JAVA_OPTS'])
                if "-buildmode=c-shared" in argv:
                    output = Path(argv[-1])
                    output.write_bytes(elf())
                    output.with_suffix(".h").write_text("/* 核心头文件 */\n")
                elif "apk" in argv:
                    self.apk(root / android.APK_OUTPUT)
                return "OFFICIAL_TLS plugins.gradle.org 200\nBETTBOX_TASK_DNS_VERIFIED\n"

            with mock.patch.object(android, "run", side_effect=fake_run), \
                    mock.patch.object(android, "source_snapshot", return_value={"head": "abc", "dirty": True}), \
                    mock.patch.object(android, "authorize_execution", return_value="a" * 64), \
                    mock.patch.object(android, "cleanup_gradle", return_value={"verified": True}) as cleanup:
                receipt_path = android.execute(root, {"Flutter": android.FLUTTER_VERSION}, self.environment())
            receipt = json.loads(receipt_path.read_text())
            self.assertEqual(receipt["status"], "passed")
            self.assertTrue(receipt["locks_unchanged"])
            self.assertFalse(receipt["release_verified"])
            self.assertEqual(len(set(homes)), 1)
            self.assertTrue(Path(homes[0]).is_relative_to(root / ".test/android-build"))
            self.assertEqual(cleanup.call_args.args[1], Path(homes[0]))
            self.assertTrue(receipt["gradle_cleanup"]["verified"])
            self.assertEqual(receipt["apk_libraries"]["lib/arm64-v8a/libclash.so"],
                             android.sha256(root / android.CORE_OUTPUT / "libclash.so"))

    def test_lock_mutation_aborts_and_writes_failure_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.create_locks(root)

            def mutate(*args, **kwargs):
                (root / "core/go.sum").write_text("漂移\n")
                return "OFFICIAL_TLS plugins.gradle.org 200\nBETTBOX_TASK_DNS_VERIFIED\n"

            with mock.patch.object(android, "run", side_effect=mutate) as run, \
                    mock.patch.object(android, "source_snapshot", return_value={"head": "abc"}), \
                    mock.patch.object(android, "authorize_execution", return_value="a" * 64):
                with self.assertRaises(RuntimeError):
                    android.execute(root, {}, self.environment())
                self.assertEqual(run.call_count, 1)
            receipt = json.loads((root / ".test/android-build/receipt.json").read_text())
            self.assertEqual(receipt["status"], "failed")
            self.assertFalse(receipt["locks_unchanged"])
            self.assertEqual(receipt["changed_locks"], ["core/go.sum"])
            self.assertFalse((root / android.CORE_OUTPUT / "libclash.so").exists())

    def test_child_errors_do_not_reveal_raw_output(self) -> None:
        result = mock.Mock(returncode=1)
        result.communicate.return_value = ("AUTH_TOKEN=hidden", None)
        with mock.patch.object(android.subprocess, "Popen", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "退出码 1") as caught:
                android.run(("go", "build"), Path("/repo"), {})
        self.assertNotIn("hidden", str(caught.exception))

    def test_default_mode_never_executes_build_or_writes_receipt(self) -> None:
        with mock.patch.object(android, "preflight", return_value=({}, self.environment())) as preflight, \
                mock.patch.object(android, "snapshot_locks", return_value={}), \
                mock.patch.object(android, "changed_locks", return_value=[]), \
                mock.patch.object(android, "execute") as execute, \
                mock.patch("builtins.print"):
            self.assertEqual(android.main([]), 0)
        execute.assert_not_called()
        preflight.assert_not_called()
        self.lease.start.assert_not_called()

    def test_network_diagnosis_stops_after_help_and_cleans_owned_home(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.create_locks(root)
            calls = []
            def probe(argv, cwd, env, **kwargs):
                calls.append(tuple(argv))
                return 'OFFICIAL_TLS plugins.gradle.org 200\nBETTBOX_TASK_DNS_VERIFIED\n'
            with mock.patch.object(android, 'run', side_effect=probe), \
                    mock.patch.object(android, 'source_snapshot', return_value={'head': 'abc'}), \
                    mock.patch.object(android, 'authorize_execution', return_value='a' * 64), \
                    mock.patch.object(android, 'cleanup_gradle', return_value={'verified': True}) as cleanup:
                path = android.execute(root, {}, self.environment(), network_check_only=True)
            receipt = json.loads(path.read_text())
            self.assertEqual(receipt['target'], 'android-official-dependency-check')
            self.assertTrue(receipt['gradle_help_verified'])
            self.assertEqual(len(calls), 2)
            self.assertIn('help', calls[1])
            self.assertFalse(any('apk' in args or '-buildmode=c-shared' in args for args in calls))
            self.assertTrue(cleanup.call_args.args[1].is_relative_to(root / '.test/android-build'))

    def test_help_failure_blocks_core_and_preserves_safe_unknown_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.create_locks(root)
            calls = []
            def probe(argv, cwd, env, **kwargs):
                calls.append(tuple(argv))
                if 'help' in argv:
                    raise android.CommandFailed('gradlew', 1, 'java.net.UnknownHostException: jitpack.io\npassword=虚构秘密')
                return 'OFFICIAL_TLS plugins.gradle.org 200\n'
            with mock.patch.object(android, 'run', side_effect=probe), \
                    mock.patch.object(android, 'source_snapshot', return_value={'head': 'abc'}), \
                    mock.patch.object(android, 'authorize_execution', return_value='a' * 64), \
                    mock.patch.object(android, 'cleanup_gradle', return_value={'verified': True}):
                with self.assertRaises(RuntimeError): android.execute(root, {}, self.environment())
            receipt = json.loads((root / '.test/android-build/receipt.json').read_text())
            self.assertEqual(receipt['safe_failure_summary']['unknown_hosts'], ['jitpack.io'])
            self.assertNotIn('虚构秘密', json.dumps(receipt))
            self.assertEqual(len(calls), 2)
            self.assertFalse((root / android.CORE_OUTPUT).exists())

    def test_failed_dns_renewal_kills_only_current_command_session(self) -> None:
        process = mock.Mock(pid=123)
        process.communicate.return_value = ('password=虚构值', None)
        lease = mock.Mock()
        lease.check.side_effect = [None, android.dependency_network.NetworkError('任务 DNS 刷新失败')]
        with mock.patch.object(android.subprocess, 'Popen', return_value=process), \
                mock.patch.object(android.os, 'killpg') as kill:
            with self.assertRaisesRegex(RuntimeError, 'DNS 刷新失败') as caught:
                android.run(('java',), Path('/repo'), {}, network_lease=lease)
        kill.assert_called_once_with(123, android.signal.SIGKILL)
        self.assertNotIn('虚构值', str(caught.exception))

    def test_studio_search_crosses_deep_ordinary_directories_and_prunes_apps(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            unrelated = base.joinpath(*('普通目录' + str(index) for index in range(12)))
            unrelated.mkdir(parents=True)
            candidate = unrelated / 'Android Studio Preview.app'
            candidate.mkdir()
            # 所有 app 内部均停止递归，包括其它产品和 Android Studio 自身。
            hidden = base / 'Other.app/Android Studio Hidden.app'
            hidden.mkdir(parents=True)
            nested = candidate / 'Android Studio Nested.app'
            nested.mkdir()
            alias = base / 'linked-install'
            alias.symlink_to(unrelated, target_is_directory=True)
            found = android.studio_candidates((base,), android.time.monotonic() + 10)
            self.assertEqual(found, {candidate})
            # 超过 8 层但没有任何候选时也不能错误拒绝或猜测 JDK。
            self.assertEqual(android.studio_candidates((unrelated / '不存在',), None), set())
            candidate.rename(unrelated / 'Other Deep.app')
            self.assertEqual(android.studio_candidates((base,), None), set())

    def test_studio_search_has_shared_entry_budget_and_absolute_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first, second = root / 'first', root / 'second'
            first.mkdir(); second.mkdir()
            (first / 'ordinary').mkdir()
            (second / 'Android Studio.app').mkdir()
            with self.assertRaisesRegex(RuntimeError, '条目预算'):
                android.studio_candidates((first, second), None, entry_budget=1)
            self.assertEqual(android.studio_candidates((first, second), None, entry_budget=2),
                             {second / 'Android Studio.app'})
            with mock.patch.object(android.time, 'monotonic', return_value=20), \
                    mock.patch.object(android.os, 'scandir') as scan, \
                    self.assertRaisesRegex(RuntimeError, '时间预算'):
                android.studio_candidates((first,), 19)
            scan.assert_not_called()
            # 初始预算有效，但目录迭代期间达到截止时间也必须立即停止。
            with mock.patch.object(android.time, 'monotonic', side_effect=[0, 0, 31]), \
                    self.assertRaisesRegex(RuntimeError, '时间预算'):
                android.studio_candidates((first,), 100)

    def test_deep_studio_candidate_selects_verified_bundle_jbr(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sdk = root / 'flutter'
            flutter = sdk / 'bin/flutter'
            flutter.parent.mkdir(parents=True); flutter.write_text('公开 fixture')
            source = sdk / 'packages/flutter_tools/lib/src/android/java.dart'
            source.parent.mkdir(parents=True)
            source.write_text("_JavaHomePathWithSource? _findJavaHome( config.getValue('jdk-dir'); androidStudio?.javaPath; platform.environment[Java.javaHomeEnvironmentVariable];")
            home = root / 'home'; home.mkdir()
            applications = home / 'Applications'
            bundle = applications.joinpath(*('目录' + str(index) for index in range(12))) / 'Android Studio.app'
            java = bundle / 'Contents/jbr/Contents/Home/bin/java'
            java.parent.mkdir(parents=True); java.write_text('公开不执行 fixture')
            with (bundle / 'Contents/Info.plist').open('wb') as stream:
                android.plistlib.dump({'CFBundleShortVersionString': '2025.1'}, stream)
            original_search = android.studio_candidates
            def only_fixture(bases, deadline):
                self.assertEqual(bases, (Path('/Applications'), applications))
                return original_search((applications,), deadline)
            with mock.patch.object(android, 'studio_candidates', side_effect=only_fixture), \
                    mock.patch.object(android, 'run', return_value='') as run:
                selected, origin = android.selected_java(flutter, root, {'HOME': str(home)}, None)
            self.assertEqual((selected, origin), (java, 'androidStudio'))
            self.assertEqual(run.call_args_list[-1].args[0], (str(java), '-version'))

    def test_flutter_configured_jdk_priority_without_doctor_or_other_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            flutter = root / 'sdk/bin/flutter'
            flutter.parent.mkdir(parents=True)
            flutter.touch()
            source = root / 'sdk/packages/flutter_tools/lib/src/android/java.dart'
            source.parent.mkdir(parents=True)
            source.write_text("_JavaHomePathWithSource? _findJavaHome( config.getValue('jdk-dir'); androidStudio?.javaPath; platform.environment[Java.javaHomeEnvironmentVariable];")
            home = root / 'home'; home.mkdir()
            (home / '.flutter_settings').write_text(json.dumps({'jdk-dir': '/selected/jdk', 'other': '虚构私有值'}))
            with mock.patch.object(android, 'run') as run:
                selected, origin = android.selected_java(flutter, root, {'HOME': str(home), 'JAVA_HOME': '/other/jdk'}, None)
            self.assertEqual(selected, Path('/selected/jdk/bin/java'))
            self.assertEqual(origin, 'flutterConfig')
            run.assert_not_called()

    def test_version_parser_accepts_initialization_preamble_but_rejects_duplicates(self) -> None:
        machine = json.dumps({"frameworkVersion": "3.44.9"})
        self.assertEqual(android.parse_flutter_version("初始化\n" + machine), "3.44.9")
        with self.assertRaises(RuntimeError):
            android.parse_flutter_version(machine + machine)

    def test_preflight_verifies_selected_jdk_and_sdk_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sdk = root / "sdk"
            cc = sdk / "ndk" / android.NDK_VERSION / "toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang"
            java = root / "jdk/bin/java"
            flutter, go = root / "flutter", root / "go"
            files = (cc, java, flutter, go, root / "android/gradlew",
                     sdk / "cmake/3.22.1/bin/cmake", sdk / "build-tools/36.0.0/zipalign",
                     sdk / "platforms/android-36/android.jar")
            for path in files:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("工具占位\n")
            props = sdk / "ndk" / android.NDK_VERSION / "source.properties"
            props.write_text(f"Pkg.Revision = {android.NDK_VERSION}\n")

            def fake_run(argv, cwd, env, **kwargs):
                if "--machine" in argv:
                    return json.dumps({"frameworkVersion": android.FLUTTER_VERSION})
                if argv[0] == str(go):
                    return f"go version go{android.GO_VERSION} darwin/arm64"
                if "doctor" in argv:
                    return f"Java binary at: {java}\n"
                if argv[0] == str(java):
                    return 'openjdk version "21.0.8"'
                if "cmake" in argv[0]:
                    return "cmake version 3.22.1"
                return "Android clang version 19.0"

            with mock.patch.object(android.platform, "system", return_value="Darwin"), \
                    mock.patch.object(android.platform, "machine", return_value="arm64"), \
                    mock.patch.object(android.shutil, "which", side_effect=lambda name, **kw: str(root / name)), \
                    mock.patch.object(android, "run", side_effect=fake_run), \
                    mock.patch.object(android, "selected_java", return_value=(java, "flutterConfig")):
                versions, env = android.preflight(root, sdk)
                self.assertEqual(versions["JDK"], "21.0.8")
                self.assertEqual(env["JAVA_HOME"], str(java.parent.parent))
                self.assertEqual(versions["GoExecutableSHA256"], android.sha256(go))
                props.write_text("Pkg.Revision = 27.0.0\n")
                with self.assertRaisesRegex(RuntimeError, "NDK"):
                    android.preflight(root, sdk)

    def test_authorization_requires_validator_and_matching_approved_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            validator = root / "validator.py"
            validator.write_text("# 测试验证器\n")
            contract = root / ".pdec/contract.yaml"
            contract.parent.mkdir()
            contract.write_text(json.dumps({"approval": {"contract_digest": "a" * 64}}))
            result = {"execution_ready": True, "framework": {
                "execution_ready": True, "contract_digest": "a" * 64},
                "android_operation": {"timeout_seconds": 2700}}
            with mock.patch.object(android, "run", return_value=json.dumps(result)) as run:
                with self.assertRaisesRegex(RuntimeError, "验证器"):
                    android.authorize_execution(root, None, {}, android.time.monotonic() + 30)
                run.assert_not_called()
                self.assertEqual(android.authorize_execution(root, validator, {},
                    android.time.monotonic() + 30), "a" * 64)
                self.assertIn("validate_android_contract.py", run.call_args.args[0][1])
                self.assertLessEqual(run.call_args.kwargs["timeout"], 30)
                result["framework"]["contract_digest"] = "b" * 64
                run.return_value = json.dumps(result)
                with self.assertRaisesRegex(RuntimeError, "摘要批准"):
                    android.authorize_execution(root, validator, {}, android.time.monotonic() + 30)

    def test_timeout_never_exposes_child_output(self) -> None:
        timeout = android.subprocess.TimeoutExpired(["go"], 1, output="SECRET=hidden")
        process = mock.Mock(pid=123)
        process.communicate.side_effect = [timeout, ("", None)]
        with mock.patch.object(android.subprocess, "Popen", return_value=process), \
                mock.patch.object(android.os, "killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "超时") as caught:
                android.run(("go",), Path("/repo"), {}, timeout=1)
        kill.assert_called_once_with(123, android.signal.SIGKILL)
        self.assertNotIn("hidden", str(caught.exception))
        with mock.patch.object(android.time, "monotonic", return_value=100):
            with self.assertRaisesRegex(RuntimeError, "总体时间"):
                android.remaining_budget(99)

    def test_timeout_and_source_drift_write_failed_receipts(self) -> None:
        failures = (android.subprocess.TimeoutExpired(["go"], 1, output="hidden"),
                    RuntimeError("源码输入发生变化"))
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.create_locks(root)
                with mock.patch.object(android, "source_snapshot", return_value={"head": "abc"}), \
                        mock.patch.object(android, "authorize_execution", return_value="a" * 64), \
                        mock.patch.object(android, "run", side_effect=failure):
                    with self.assertRaises(RuntimeError):
                        android.execute(root, {}, self.environment())
                receipt = json.loads((root / ".test/android-build/receipt.json").read_text())
                self.assertEqual(receipt["status"], "failed")
                self.assertEqual(receipt["approved_contract_digest"], "a" * 64)
                self.assertNotIn("hidden", receipt["failure_reason"])

    def test_final_lock_drift_overrides_passed_status(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.create_locks(root)

            def fake_run(argv, cwd, env, **kwargs):
                if "-buildmode=c-shared" in argv:
                    output = Path(argv[-1])
                    output.write_bytes(elf())
                    output.with_suffix(".h").write_text("头文件")
                elif "apk" in argv:
                    self.apk(root / android.APK_OUTPUT)
                return "OFFICIAL_TLS plugins.gradle.org 200\nBETTBOX_TASK_DNS_VERIFIED\n"

            with mock.patch.object(android, "run", side_effect=fake_run), \
                    mock.patch.object(android, "source_snapshot", return_value={"head": "abc"}), \
                    mock.patch.object(android, "authorize_execution", return_value="a" * 64), \
                    mock.patch.object(android, "cleanup_gradle", return_value={"verified": True}), \
                    mock.patch.object(android, "changed_locks", side_effect=[[], [], [], [], [], [], ["core/go.sum"]]):
                with self.assertRaisesRegex(RuntimeError, "最终依赖"):
                    android.execute(root, {}, self.environment())
            receipt = json.loads((root / ".test/android-build/receipt.json").read_text())
            self.assertEqual(receipt["status"], "failed")
            self.assertFalse(receipt["locks_unchanged"])

    def test_source_hash_uses_current_bytes_and_excludes_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "lib").mkdir()
            source = root / "lib/main.dart"
            source.write_text("实际源码")
            replies = ["abc\n", " M lib/main.dart\n", "lib/main.dart\0android/local.properties\0"]
            with mock.patch.object(android, "run", side_effect=replies):
                before = android.source_snapshot(root, {}, android.time.monotonic() + 30)
            source.write_text("变动后的源码")
            with mock.patch.object(android, "run", side_effect=replies):
                after = android.source_snapshot(root, {}, android.time.monotonic() + 30)
            self.assertTrue(before["dirty"])
            self.assertEqual(before["source_file_count"], 1)
            self.assertNotEqual(before["source_sha256"], after["source_sha256"])

    def test_gradle_stop_is_bounded_and_scoped_to_owned_home(self) -> None:
        root, home = Path("/repo"), Path("/repo/.test/android-build/gradle-home-unique")
        with mock.patch.object(android, "run", return_value="") as run, \
                mock.patch.object(android, "owned_gradle_processes", return_value={}):
            result = android.cleanup_gradle(root, home, {"GRADLE_USER_HOME": str(home)},
                                            android.time.monotonic() + 30)
        self.assertTrue(result["verified"])
        stop = run.call_args.args[0]
        self.assertEqual(stop, ("/repo/android/gradlew", "--stop", "--gradle-user-home",
                                str(home), "-Dorg.gradle.daemon=false"))
        self.assertLessEqual(run.call_args.kwargs["timeout"], 15)

    def test_unproven_holder_is_not_killed_or_marked_verified(self) -> None:
        root, home = Path("/repo"), Path("/repo/.test/android-build/gradle-home-unique")
        with mock.patch.object(android, "run", return_value=""), \
                mock.patch.object(android, "owned_gradle_processes", side_effect=RuntimeError("归属未知")), \
                mock.patch.object(android.os, "kill") as kill:
            result = android.cleanup_gradle(root, home, {}, android.time.monotonic() + 30)
        self.assertFalse(result["verified"])
        kill.assert_not_called()

    def test_holder_requires_owned_file_and_gradle_class(self) -> None:
        root, home = Path("/repo"), Path("/repo/.test/android-build/gradle-home-unique")
        lsof = f"p123\ncjava\nn{home}/daemon/8.14/daemon-123.out.log\n"
        with mock.patch.object(android, "run", side_effect=[lsof, "unrelated-process\n"]):
            with self.assertRaisesRegex(RuntimeError, "无法授权终止"):
                android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30)
        with mock.patch.object(android, "run", side_effect=[lsof,
                "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14\n", "Oct 7 10:00\n"]):
            self.assertEqual(android.owned_gradle_processes(home, root, {},
                android.time.monotonic() + 30), {123: "Oct 7 10:00"})

    def test_unverified_cleanup_overrides_success_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.create_locks(root)

            def fake_run(argv, cwd, env, **kwargs):
                if "-buildmode=c-shared" in argv:
                    Path(argv[-1]).write_bytes(elf())
                    Path(argv[-1]).with_suffix(".h").write_text("头文件")
                elif "apk" in argv:
                    self.apk(root / android.APK_OUTPUT)
                return "OFFICIAL_TLS plugins.gradle.org 200\nBETTBOX_TASK_DNS_VERIFIED\n"

            with mock.patch.object(android, "run", side_effect=fake_run), \
                    mock.patch.object(android, "source_snapshot", return_value={"head": "abc"}), \
                    mock.patch.object(android, "authorize_execution", return_value="a" * 64), \
                    mock.patch.object(android, "cleanup_gradle", return_value={"verified": False}):
                with self.assertRaisesRegex(RuntimeError, "终止证据不足"):
                    android.execute(root, {}, self.environment())
            receipt = json.loads((root / ".test/android-build/receipt.json").read_text())
            self.assertEqual(receipt["status"], "failed")
            self.assertFalse(receipt["gradle_cleanup"]["verified"])

    def test_failure_summary_extracts_public_fields_without_raw_text(self) -> None:
        summary = android.safe_failure_summary("""
Execution failed for task ':app:compileDebugKotlin'.
Could not resolve org.example.public:widget:1.2.3.
/Users/example/project/lib/main.dart:27:9: error: arbitrary quoted 'internal value'
CMake configured unsuccessfully
unknown failure details 'unclassified private text'
""")
        self.assertIn(":app:compileDebugKotlin", summary["tasks"])
        self.assertIn("org.example.public:widget:1.2.3", summary["dependencies"])
        self.assertIn("lib/main.dart:27:9", summary["locations"])
        text = json.dumps(summary)
        for private in ("Users", "internal value", "unclassified private text", "example/project"):
            self.assertNotIn(private, text)

    def test_failure_summary_drops_secret_shapes_and_sensitive_lines(self) -> None:
        secret = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"
        output = "\n".join([
            "error: secret=fictional-value lib/private.dart:1",
            "error: token=fictional-value lib/private.dart:2",
            "error: password='fictional-value' lib/private.dart:3",
            "error: Authorization Bearer fictional-value lib/private.dart:4",
            "error: cookie=fictional-value lib/private.dart:5",
            "error: credentials='fictional-value' lib/private.dart:6",
            f"error: {secret} lib/private.dart:7",
            "Could not resolve org.secretless:library:1.0 https://fictional:pass@host/path",
            "error: https://host/path?value=fictional-value lib/private.dart:8",
            "error: fictional-person@example.com lib/private.dart:9",
            "unclassified 'fictional quoted value'",
        ])
        summary = android.safe_failure_summary(output)
        self.assertEqual(summary["categories"], ["错误未匹配安全公开诊断字段"])
        self.assertEqual(summary["locations"], [])
        self.assertNotIn("fictional", json.dumps(summary))
        self.assertNotIn(secret, json.dumps(summary))

    def test_failure_summary_task_guards_and_public_exception_classes(self) -> None:
        guards = ('任务 HTTP 与 HTTPS 代理未注入实际 Gradle JVM', '任务代理禁止绕过策略未生效',
                  '任务 DNS 映射未注入实际 Gradle JVM', '任务 DNS 缓存策略未生效', '未知主机未被拒绝',
                  '任务代理选择失败', '任务代理地址失败', '入口范围失败', '任务 DNS 缓存策略失败',
                  'DNS 闭包失败', '官方主机直接解析未被拒绝', '本机 localhost 解析越出回环',
                  '官方 TLS 探测 HTTP 失败', '官方重定向次数超限')
        for guard in guards:
            with self.subTest(guard=guard):
                summary = android.safe_failure_summary('> ' + guard)
                self.assertIn(guard, summary['categories'])
        name = 'org.codehaus.groovy.control.MultipleCompilationErrorsException'
        summary = android.safe_failure_summary('Caused by: ' + name + ': opaque quoted "fictional detail"')
        self.assertEqual(summary['exceptions'], [name])
        self.assertNotIn('fictional detail', json.dumps(summary))
        self.assertEqual(android.safe_failure_summary('unknown.vendor.PrivateError: opaque')['exceptions'], [])
        for line in ('password=fake java.lang.IllegalStateException',
                     'java.lang.IllegalStateException https://host/path?value=fake',
                     'java.lang.IllegalStateException ' + 'A' * 64):
            self.assertEqual(android.safe_failure_summary(line)['exceptions'], [])

    def test_failure_summary_only_known_generated_basename_and_numeric_line(self) -> None:
        prefix = '/Users/public/project/.test/android-build/gradle-home-abcdefghijklmnop/init.d/'
        summary = android.safe_failure_summary("Initialization script '" + prefix + "task-network.gradle' line: 5")
        self.assertEqual(summary['locations'], ['task-network.gradle:5'])
        self.assertNotIn(prefix, json.dumps(summary))
        for suffix in ("unknown-file.gradle' line: 5", "task-network.gradle' line: 5 arbitrary-text",
                       "task-network.gradle' line: opaque"):
            self.assertEqual(android.safe_failure_summary("Initialization script '" + prefix + suffix)['locations'], [])
        self.assertEqual(android.safe_failure_summary("Initialization script '/password/fake/task-network.gradle' line: 5")['locations'], [])

    def test_failure_summary_is_bounded_and_unknown_output_is_not_preserved(self) -> None:
        output = "\n".join(f"Execution failed for task ':app:task{index}'.\nlib/main.dart:{index}: error: unknown" for index in range(100))
        summary = android.safe_failure_summary(output)
        self.assertLessEqual(sum(map(len, summary.values())), 8)
        self.assertEqual(android.safe_failure_summary("unclassified opaque payload")
                         ["categories"], ["错误未匹配安全公开诊断字段"])


    def release_fixture(self, *, credential_failure=False, signature_failure=False, cleanup_verified=True, source_drift=False, alignment_failure=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.create_locks(root)
            calls = []
            signed = {**self.environment(), **{key: 'PUBLIC_TEST_SECRET' for key in android.SIGNING_KEYS}}
            def fake_run(argv, cwd, env, **kwargs):
                calls.append((tuple(argv), dict(env), kwargs))
                if '-buildmode=c-shared' in argv:
                    Path(argv[-1]).write_bytes(elf())
                    Path(argv[-1]).with_suffix('.h').write_text('公开头文件')
                elif 'apk' in argv:
                    self.apk(root / android.RELEASE_APK_OUTPUT)
                elif alignment_failure and Path(argv[0]).name == 'zipalign':
                    raise RuntimeError('公开对齐校验失败')
                return 'OFFICIAL_TLS plugins.gradle.org 200\nBETTBOX_TASK_DNS_VERIFIED\n'
            credential = android.release_signing.SigningFailure('正式签名环境不可用') if credential_failure else None
            signature = android.release_signing.SigningFailure('正式 APK 验签失败') if signature_failure else None
            with mock.patch.object(android, 'run', side_effect=fake_run), \
                    mock.patch.object(android, 'source_snapshot', return_value={'head': 'public'}, side_effect=([{'head': 'public'}] * 8 + [{'head': 'changed'}] * 2) if source_drift else None), \
                    mock.patch.object(android, 'authorize_execution', return_value='a' * 64), \
                    mock.patch.object(android, 'cleanup_gradle', return_value={'verified': cleanup_verified}) as cleanup, \
                    mock.patch.object(android.release_signing, 'signing_environment', return_value=signed, side_effect=credential) as signing, \
                    mock.patch.object(android.release_signing, 'verify_signed_apk', return_value={'verified': True, 'certificate_sha256': android.release_signing.CERTIFICATE_SHA256, 'signers': 1}, side_effect=signature) as verify:
                if credential_failure or signature_failure or not cleanup_verified or source_drift or alignment_failure:
                    with self.assertRaises(RuntimeError):
                        android.execute(root, {}, self.environment(), release=True)
                else:
                    android.execute(root, {}, self.environment(), release=True)
            receipt = json.loads((root / '.test/android-build/receipt.json').read_text())
            self.assertNotIn('PUBLIC_TEST_SECRET', json.dumps(receipt))
            self.assertFalse(receipt['release_verified'])
            if not credential_failure:
                self.assertFalse(any(key in signed for key in android.SIGNING_KEYS))
            self.assertFalse(any(key in cleanup.call_args.args[2] for key in android.SIGNING_KEYS))
            return receipt, calls, signing, verify

    def test_release_plan_is_explicit_and_selects_release_artifact(self):
        plan = android.command_plan(Path('/repo'), self.environment(), Path('/stage'), release=True)
        self.assertIn('--release', plan[2].argv)
        self.assertNotIn('--debug', plan[2].argv)
        self.assertEqual(plan[3].argv[-1], str(Path('/repo') / android.RELEASE_APK_OUTPUT))
        self.assertFalse(any(key in command.env for command in plan for key in android.SIGNING_KEYS))

    def test_release_injects_only_apk_and_verifies_public_identity(self):
        receipt, calls, signing, verify = self.release_fixture()
        self.assertEqual(receipt['status'], 'passed')
        self.assertTrue(receipt['signature_verified'])
        self.assertEqual(receipt['apk']['path'], android.RELEASE_APK_OUTPUT.as_posix())
        for argv, env, options in calls:
            self.assertNotIn('PUBLIC_TEST_SECRET', str(argv))
            if 'apk' in argv:
                self.assertTrue(options['sensitive_output'])
                self.assertTrue(all(key in env for key in android.SIGNING_KEYS))
            else:
                self.assertFalse(any(key in env for key in android.SIGNING_KEYS))
        signing.assert_called_once(); verify.assert_called_once()
        self.assertFalse(any(key in verify.call_args.args[1] for key in android.SIGNING_KEYS))

    def test_release_missing_key_blocks_apk_and_signature_failure_blocks_pass(self):
        receipt, calls, _, verify = self.release_fixture(credential_failure=True)
        self.assertEqual(receipt['status'], 'failed')
        self.assertFalse(any('apk' in argv for argv, _, _ in calls))
        verify.assert_not_called()
        receipt, _, _, _ = self.release_fixture(signature_failure=True)
        self.assertEqual(receipt['status'], 'failed')
        self.assertFalse(receipt['signature_verified'])
        receipt, _, _, _ = self.release_fixture(cleanup_verified=False)
        self.assertEqual(receipt['status'], 'failed')


    def test_release_source_drift_and_alignment_failure_cannot_pass(self):
        receipt, _, _, _ = self.release_fixture(source_drift=True)
        self.assertEqual(receipt['status'], 'failed')
        self.assertFalse(receipt['source_unchanged'])
        receipt, _, _, verify = self.release_fixture(alignment_failure=True)
        self.assertEqual(receipt['status'], 'failed')
        self.assertFalse(receipt['signature_verified'])
        verify.assert_not_called()

    def test_release_sensitive_run_never_parses_returns_or_reports_output(self):
        for code in (0, 1):
            process = mock.Mock(returncode=code)
            process.communicate.return_value = ('PUBLIC_TEST_SECRET arbitrary task :secret', None)
            with mock.patch.object(android.subprocess, 'Popen', return_value=process), \
                    mock.patch.object(android, 'safe_failure_summary') as summary, \
                    mock.patch.object(android.dependency_network, 'unknown_hosts') as hosts:
                if code:
                    with self.assertRaisesRegex(RuntimeError, '^正式 APK 构建失败，工具正文已丢弃$'):
                        android.run(('flutter',), Path('/public'), {}, sensitive_output=True)
                else:
                    self.assertEqual(android.run(('flutter',), Path('/public'), {}, sensitive_output=True), '')
                summary.assert_not_called(); hosts.assert_not_called()

    def test_release_plan_and_incompatible_flags_never_access_credentials(self):
        with mock.patch.object(android, 'snapshot_locks', return_value={}), \
                mock.patch.object(android, 'changed_locks', return_value=[]), \
                mock.patch.object(android, 'preflight') as preflight, \
                mock.patch.object(android, 'execute') as execute, \
                mock.patch.object(android.release_signing, 'signing_environment') as signing, \
                mock.patch.object(android.release_signing, 'verify_signed_apk') as verify, \
                mock.patch('builtins.print'):
            self.assertEqual(android.main(['--release']), 0)
            with self.assertRaises(SystemExit):
                android.main(['--release', '--network-check-only'])
        preflight.assert_not_called(); execute.assert_not_called(); signing.assert_not_called(); verify.assert_not_called()

    def test_release_low_budget_never_reads_credentials(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.create_locks(root)
            with mock.patch.object(android, 'run', return_value='OFFICIAL_TLS plugins.gradle.org 200\nBETTBOX_TASK_DNS_VERIFIED\n'), \
                    mock.patch.object(android, 'source_snapshot', return_value={'head': 'public'}), \
                    mock.patch.object(android, 'authorize_execution', return_value='a' * 64), \
                    mock.patch.object(android, 'cleanup_gradle', return_value={'verified': True}), \
                    mock.patch.object(android.release_signing, 'signing_environment') as signing, \
                    mock.patch.object(android.release_signing, 'verify_signed_apk') as verify:
                with self.assertRaises(RuntimeError):
                    android.execute(root, {}, self.environment(), release=True, deadline=android.time.monotonic() + 140)
            signing.assert_not_called(); verify.assert_not_called()

    def test_release_requires_explicit_approved_operation_before_credentials(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); (root / '.pdec').mkdir()
            validator = root / 'validator'; validator.write_text('PUBLIC_NOT_EXECUTED')
            operation = {'executor': 'local-mac', 'target_os': 'android', 'target_arch': 'arm64',
                'argv': ['python3', 'scripts/build_android.py', '--execute', '--release'], 'cwd': '.',
                'timeout_seconds': android.BUILD_BUDGET_SECONDS, 'artifacts': [android.RELEASE_APK_OUTPUT.as_posix()]}
            contract = {'approval': {'contract_digest': 'a' * 64}}
            path = root / '.pdec/contract.yaml'; path.write_text(json.dumps(contract))
            result = {'execution_ready': True, 'framework': {'execution_ready': True, 'contract_digest': 'a' * 64},
                      'android_operation': {'timeout_seconds': android.BUILD_BUDGET_SECONDS}}
            with mock.patch.object(android, 'run', side_effect=lambda *a, **k: json.dumps(result)) as runner:
                with self.assertRaisesRegex(RuntimeError, '契约时间预算'):
                    android.authorize_execution(root, validator, {}, android.time.monotonic() + 120, release=True)
                self.assertIn('--release', runner.call_args.args[0])
                contract['platform_extensions'] = {'android_release': operation}
                path.write_text(json.dumps(contract)); result['release_operation'] = operation
                self.assertEqual(android.authorize_execution(root, validator, {}, android.time.monotonic() + 120, release=True), 'a' * 64)
                result['release_operation'] = {**operation, 'artifacts': ['outside.apk']}
                with self.assertRaisesRegex(RuntimeError, '正式 APK 构建扩展'):
                    android.authorize_execution(root, validator, {}, android.time.monotonic() + 120, release=True)
                self.assertEqual(android.authorize_execution(root, validator, {}, android.time.monotonic() + 120), 'a' * 64)
                self.assertNotIn('--release', runner.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
