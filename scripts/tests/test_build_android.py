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


def dynamic_elf(names: tuple[bytes, ...] = (b"libclash.so",), *, terminate: bool = True) -> bytes:
    """构造真实地址映射的 ELF64 动态段，包含系统库和核心依赖。"""
    strings = bytearray(b"\0")
    indexes = []
    for name in names:
        indexes.append(len(strings))
        strings.extend(name + b"\0")
    entries = [(5, 0x4000 + 512), (10, len(strings))]
    entries.extend((1, index) for index in indexes)
    if terminate:
        entries.append((0, 0))
    data = bytearray(512 + len(strings))
    data[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", data, 18, 183)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HH", data, 54, 56, 2)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 4, 0, 0x4000, 0, len(data), len(data), 16384)
    struct.pack_into("<IIQQQQQQ", data, 120, 2, 4, 256, 0x4100, 0, len(entries) * 16, len(entries) * 16, 8)
    for index, entry in enumerate(entries):
        struct.pack_into("<qQ", data, 256 + index * 16, *entry)
    data[512:] = strings
    return bytes(data)


class AndroidLinkerRegressionTest(unittest.TestCase):
    def test_core_requires_basename_dependency_and_preserves_alignment(self) -> None:
        android.verify_elf(dynamic_elf((b"libclash.so", b"libc.so")), "lib/arm64-v8a/libcore.so")
        with self.assertRaises(RuntimeError):
            android.verify_elf(dynamic_elf((b"libc.so",)), "libcore.so")
        with self.assertRaises(RuntimeError):
            android.verify_elf(elf(), "libcore.so")
        # Go 核心自身可以没有动态依赖，不能把 JNI 依赖条件误套到全部库。
        android.verify_elf(elf(), "libclash.so")
        data = bytearray(dynamic_elf())
        struct.pack_into("<Q", data, 112, 4096)
        with self.assertRaises(RuntimeError):
            android.verify_elf(bytes(data), "libcore.so")

    def test_paths_and_unsafe_names_fail_without_echoing_input(self) -> None:
        for name in (b"/fixture/project/jniLibs/libclash.so", b"../libclash.so", b"dir/libclash.so",
                     b"dir\\libclash.so", b"", b".", b"..", b"lib\xff.so", b"lib core.so"):
            with self.subTest(name=name):
                with self.assertRaises(RuntimeError) as failure:
                    android.verify_elf(dynamic_elf((name,)), "libcore.so")
                self.assertNotIn("/fixture/project", str(failure.exception))

    def test_dynamic_table_termination_size_and_unique_segment(self) -> None:
        cases = [dynamic_elf(terminate=False)]
        data = bytearray(dynamic_elf())
        struct.pack_into("<Q", data, 152, 63)
        cases.append(bytes(data))
        data = bytearray(dynamic_elf())
        struct.pack_into("<Q", data, 128, len(data))
        cases.append(bytes(data))
        data = bytearray(dynamic_elf())
        struct.pack_into("<I", data, 64, 2)
        cases.append(bytes(data))
        for data in cases:
            with self.subTest(size=len(data)), self.assertRaises(RuntimeError):
                android.verify_elf(data, "libcore.so")

    def test_string_table_mapping_bounds_and_dependency_termination(self) -> None:
        cases = []
        for pos, value in ((264, 0x9000), (280, 9999), (296, 9999)):
            data = bytearray(dynamic_elf())
            struct.pack_into("<Q", data, pos, value)
            cases.append(bytes(data))
        data = bytearray(dynamic_elf())
        data[-1] = ord("x")
        cases.append(bytes(data))
        data = bytearray(dynamic_elf())
        struct.pack_into("<q", data, 272, 5)
        cases.append(bytes(data))
        data = bytearray(dynamic_elf())
        struct.pack_into("<q", data, 272, 11)
        cases.append(bytes(data))
        # 字符串落在 LOAD 的内存零填充区而非文件区，不能拿零填充伪造终止符。
        data = bytearray(dynamic_elf())
        struct.pack_into("<Q", data, 96, 512)
        cases.append(bytes(data))
        data = bytearray(dynamic_elf())
        struct.pack_into("<H", data, 56, 3)
        struct.pack_into("<IIQQQQQQ", data, 176, 1, 4, 0, 0x4000, 0, len(data), len(data), 16384)
        cases.append(bytes(data))
        cases.append(dynamic_elf((b"libclash.so", b"libclash.so")))
        for data in cases:
            with self.subTest(size=len(data)), self.assertRaises(RuntimeError):
                android.verify_elf(data, "libcore.so")

    def test_dynamic_segment_runtime_mapping_matches_file_table(self) -> None:
        cases = []
        data = bytearray(dynamic_elf())
        struct.pack_into("<Q", data, 136, 0x4110)
        cases.append(bytes(data))
        data = bytearray(dynamic_elf())
        struct.pack_into("<Q", data, 136, 0x4400)
        struct.pack_into("<Q", data, 104, 4096)
        cases.append(bytes(data))
        for data in cases:
            with self.subTest(size=len(data)), self.assertRaises(RuntimeError):
                android.verify_elf(data, "libcore.so")

    def test_apk_gate_rejects_path_linked_jni_without_changing_core_sha(self) -> None:
        clash = dynamic_elf((b"libc.so",))
        import hashlib
        core_sha = hashlib.sha256(clash).hexdigest()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "app.apk"
            for needed, rejected in ((b"/fixture/jniLibs/libclash.so", True), (b"libclash.so", False)):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("lib/arm64-v8a/libclash.so", clash)
                    archive.writestr("lib/arm64-v8a/libcore.so", dynamic_elf((needed,)))
                    archive.writestr("lib/arm64-v8a/libflutter.so", elf())
                if rejected:
                    with self.assertRaises(RuntimeError):
                        android.verify_apk(path)
                else:
                    self.assertEqual(android.verify_apk(path)["lib/arm64-v8a/libclash.so"], core_sha)


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
                archive.writestr(f"lib/{abi}/{name}", dynamic_elf() if name == "libcore.so" else elf())

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

            cleanup_finished = [False]
            def cleanup(*args, **kwargs):
                cleanup_finished[0] = True
                return {"verified": True}
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
                    mock.patch.object(android, "cleanup_gradle", side_effect=cleanup), \
                    mock.patch.object(android, "changed_locks", side_effect=lambda *args: ["core/go.sum"] if cleanup_finished[0] else []):
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
        calls = [call for call in run.call_args_list if "--stop" in call.args[0]]
        self.assertEqual(len(calls), 1)
        stop = calls[0].args[0]
        self.assertEqual(stop, ("/repo/android/gradlew", "--stop", "--gradle-user-home",
                                str(home), "-Dorg.gradle.daemon=false"))
        self.assertLessEqual(calls[0].kwargs["timeout"], 15)

    def test_unproven_holder_is_not_killed_or_marked_verified(self) -> None:
        root, home = Path("/repo"), Path("/repo/.test/android-build/gradle-home-unique")
        with mock.patch.object(android, "run", return_value=""), \
                mock.patch.object(android, "owned_gradle_processes", side_effect=RuntimeError("归属未知")), \
                mock.patch.object(android.os, "kill") as kill:
            result = android.cleanup_gradle(root, home, {}, android.time.monotonic() + 30)
        self.assertFalse(result["verified"])
        kill.assert_not_called()

    def test_holder_requires_kernel_java_owned_fd_exact_class_and_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); home = root / '.test/android-build/gradle-home-unique'; home.mkdir(parents=True)
            java = root / 'Android Studio.app/Contents/jbr/bin/java'; java.parent.mkdir(parents=True); java.write_bytes(b'PUBLIC_JAVA_FIXTURE')
            identity = android.JavaIdentity(java.resolve(), android.sha256(java))
            lsof = f'p123\ncjava\nf7\nn{home}/daemon.log\n'
            for main_class in ('org.gradle.launcher.daemon.bootstrap.GradleDaemon',
                               'worker.org.gradle.process.internal.worker.GradleWorkerMain',
                               'org.jetbrains.kotlin.daemon.KotlinCompileDaemon'):
                arguments = (str(java), f'-Dgradle.user.home={home}', main_class)
                with mock.patch.object(android, 'run', side_effect=[lsof, 'Wed Oct  7 10:00:00 2026', 'Wed Oct  7 10:00:00 2026']), \
                        mock.patch.object(android, 'process_executable', return_value=java.resolve()), \
                        mock.patch.object(android, 'process_arguments', return_value=arguments):
                    owned = android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30, identity)
                self.assertEqual(owned[123].started, 'Wed Oct  7 10:00:00 2026')
                self.assertEqual(owned[123].executable, java.resolve())
            for executable, arguments in [(root / 'other/java', (str(java), f'-Dgradle.user.home={home}', main_class)),
                    (java.resolve(), (str(java), main_class)),
                    (java.resolve(), (str(java), f'-Dgradle.user.home={home}', 'thirdparty.GradleWorkerMain')),
                    (java.resolve(), (str(java), f'-Dgradle.user.home={home}', '-cp', main_class, 'unknown.Main'))]:
                with mock.patch.object(android, 'run', side_effect=[lsof, 'Wed Oct  7 10:00:00 2026']), \
                        mock.patch.object(android, 'process_executable', return_value=executable), \
                        mock.patch.object(android, 'process_arguments', return_value=arguments), \
                        mock.patch.object(android.os, 'kill') as kill:
                    with self.assertRaisesRegex(RuntimeError, '无法授权终止'):
                        android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30, identity)
                    kill.assert_not_called()
            with mock.patch.object(android, 'run', return_value=lsof), \
                    mock.patch.object(android, 'process_executable') as executable:
                with self.assertRaisesRegex(RuntimeError, '预检选定 Java'):
                    android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30)
                executable.assert_not_called()
            with mock.patch.object(android, 'run', return_value='p123\ncjava\nf8\nn/PUBLIC/another-task/cache.jar\n'), \
                    mock.patch.object(android, 'process_executable') as executable, \
                    mock.patch.object(android.os, 'kill') as kill:
                with self.assertRaisesRegex(RuntimeError, '文件描述符归属'):
                    android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30, identity)
                executable.assert_not_called(); kill.assert_not_called()
            # 相同路径的文件被换掉也不能认定为预检 Java。
            java.write_bytes(b'CHANGED_PUBLIC_JAVA')
            with mock.patch.object(android, 'run', return_value=lsof), \
                    mock.patch.object(android, 'process_executable') as executable:
                with self.assertRaisesRegex(RuntimeError, '入口摘要变化'):
                    android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30, identity)
                executable.assert_not_called()

    def test_pid_reuse_or_exit_during_kernel_identity_read_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); home = root / '.test/android-build/gradle-home-unique'; home.mkdir(parents=True)
            java = root / 'java'; java.write_bytes(b'PUBLIC_JAVA')
            identity = android.JavaIdentity(java.resolve(), android.sha256(java))
            lsof = f'p123\ncjava\nf9\nn{home}/daemon.log\n'
            arguments = (str(java), f'-Dgradle.user.home={home}', 'org.gradle.launcher.daemon.bootstrap.GradleDaemon')
            with mock.patch.object(android, 'run', side_effect=[lsof, 'Wed Oct  7 10:00:00 2026', 'Wed Oct  7 10:00:01 2026']), \
                    mock.patch.object(android, 'process_executable', return_value=java.resolve()), \
                    mock.patch.object(android, 'process_arguments', return_value=arguments):
                self.assertEqual(android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30, identity), {})
            with mock.patch.object(android, 'run', side_effect=[lsof, 'Wed Oct  7 10:00:00 2026']), \
                    mock.patch.object(android, 'process_executable', side_effect=ProcessLookupError), \
                    mock.patch.object(android, 'process_arguments') as arguments:
                self.assertEqual(android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30, identity), {})
                arguments.assert_not_called()
            with mock.patch.object(android, 'run', return_value=f'p123\ncjava\nfmem\nn{home}/cache.jar\n'), \
                    mock.patch.object(android, 'process_executable') as executable:
                self.assertEqual(android.owned_gradle_processes(home, root, {}, android.time.monotonic() + 30, identity), {})
                executable.assert_not_called()

    def test_kernel_argv_prefix_excludes_environment_and_buffer_is_zeroed(self) -> None:
        arguments = ('/PUBLIC/Android Studio.app/bin/java', '-Dgradle.user.home=/PUBLIC/home', 'org.jetbrains.kotlin.daemon.KotlinCompileDaemon')
        prefix = struct.pack('=i', len(arguments)) + b'/PUBLIC/java\0\0' + b'\0'.join(value.encode() for value in arguments) + b'\0'
        payload = prefix + b'PUBLIC_FAKE_PASSWORD=DO_NOT_RETURN_ENV\0'
        allocated = []
        def query(mib, count, buffer, size, new, new_size):
            self.assertEqual(list(mib), [1, 49, 123]); self.assertEqual(count, 3)
            size._obj.value = len(payload)
            if buffer is not None:
                allocated.append(buffer)
                android.ctypes.memmove(buffer, payload, len(payload))
            return 0
        library = mock.Mock(); library.sysctl = mock.Mock(side_effect=query)
        with mock.patch.object(android.ctypes, 'CDLL', return_value=library):
            result = android.process_arguments(123)
        self.assertEqual(result, arguments)
        self.assertNotIn('DO_NOT_RETURN_ENV', str(result))
        self.assertEqual(bytes(allocated[0]), b'\0' * len(payload))
        for payload in (struct.pack('=i', 99999) + b'PUBLIC\0', struct.pack('=i', 1) + b'PUBLIC\0\0\xff\0',
                        struct.pack('=i', 2) + b'PUBLIC\0\0one\0'):
            allocated.clear()
            with mock.patch.object(android.ctypes, 'CDLL', return_value=library):
                with self.assertRaisesRegex(RuntimeError, '内核参数'):
                    android.process_arguments(123)
            self.assertEqual(bytes(allocated[0]), b'\0' * len(payload))

    def test_kernel_executable_with_spaces_and_sysctl_bounds_fail_safely(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            java = Path(temp) / 'Android Studio.app/bin/java'
            java.parent.mkdir(parents=True); java.write_bytes(b'PUBLIC_JAVA')
            captured = []
            def path_query(pid, buffer, size):
                captured.append(buffer)
                raw = str(java.resolve()).encode() + b'\0'
                android.ctypes.memmove(buffer, raw, len(raw))
                return len(raw) - 1
            library = mock.Mock(); library.proc_pidpath = mock.Mock(side_effect=path_query)
            with mock.patch.object(android.ctypes, 'CDLL', return_value=library):
                self.assertEqual(android.process_executable(123), java.resolve())
            self.assertEqual(bytes(captured[0]), b'\0' * 4096)
            library.proc_pidpath.side_effect = None; library.proc_pidpath.return_value = 0
            for code, expected in [(android.errno.ESRCH, ProcessLookupError), (android.errno.EPERM, RuntimeError)]:
                with mock.patch.object(android.ctypes, 'CDLL', return_value=library), \
                        mock.patch.object(android.ctypes, 'get_errno', return_value=code):
                    with self.assertRaises(expected): android.process_executable(123)
        def oversized(mib, count, buffer, size, new, new_size):
            size._obj.value = 1048577
            return 0
        library = mock.Mock(); library.sysctl = mock.Mock(side_effect=oversized)
        with mock.patch.object(android.ctypes, 'CDLL', return_value=library), \
                mock.patch.object(android.ctypes, 'create_string_buffer') as allocate:
            with self.assertRaisesRegex(RuntimeError, '内核参数范围'):
                android.process_arguments(123)
            allocate.assert_not_called()

    def test_task_candidate_scan_reads_only_same_uid_selected_java_and_exact_home(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); home = root / 'gradle-home-public'; home.mkdir()
            java = root / 'java'; java.write_bytes(b'PUBLIC_JAVA')
            identity = android.JavaIdentity(java.resolve(), android.sha256(java))
            uid = android.os.getuid()
            raw = f'101 {uid} java\n102 {uid} java\n103 {uid+1} java\n104 {uid} java\n'
            argv = (str(java), f'-Dgradle.user.home={home}', 'org.jetbrains.kotlin.daemon.KotlinCompileDaemon')
            with mock.patch.object(android, 'run', return_value=raw) as run, \
                    mock.patch.object(android, 'process_executable', side_effect=[root/'other', java.resolve(), java.resolve()]) as executable, \
                    mock.patch.object(android, 'process_arguments', side_effect=[argv, (str(java), 'unrelated.Main')]) as arguments, \
                    mock.patch.object(android.os, 'kill') as kill:
                result = android.task_gradle_candidates(home, root, {}, android.time.monotonic()+30, identity)
            self.assertEqual(result, [102]); self.assertEqual(arguments.call_count, 2)
            self.assertEqual([call.args[0] for call in executable.call_args_list], [101, 102, 104])
            self.assertEqual(run.call_args.args[0], ('ps', '-axo', 'pid=,uid=,ucomm='))
            kill.assert_not_called()

    def test_protected_non_java_entry_does_not_block_task_candidate_scan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); home = root / 'gradle-home-public'; home.mkdir()
            java = root / 'java'; java.write_bytes(b'PUBLIC_JAVA')
            identity = android.JavaIdentity(java.resolve(), android.sha256(java)); uid = android.os.getuid()
            def listing(argv, *args, **kwargs):
                if argv[-1] == 'pid=,uid=,ucomm=':
                    return f'101 {uid} Protected System App\n'
                return f'101 {uid}\n'
            with mock.patch.object(android, 'run', side_effect=listing), \
                    mock.patch.object(android, 'process_executable', side_effect=RuntimeError('PUBLIC_PROTECTED_ENTRY')) as executable:
                result = android.task_gradle_candidates(home, root, {}, android.time.monotonic()+30, identity)
            self.assertEqual(result, []); executable.assert_not_called()

    def test_unreadable_java_candidate_keeps_scan_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); home = root / 'gradle-home-public'; home.mkdir()
            java = root / 'java'; java.write_bytes(b'PUBLIC_JAVA')
            identity = android.JavaIdentity(java.resolve(), android.sha256(java))
            with mock.patch.object(android, 'run', return_value=f'101 {android.os.getuid()} java\n'), \
                    mock.patch.object(android, 'process_executable', side_effect=RuntimeError('PUBLIC_UNREADABLE_JAVA')):
                with self.assertRaises(RuntimeError):
                    android.task_gradle_candidates(home, root, {}, android.time.monotonic()+30, identity)

    def test_cleanup_no_fd_task_candidate_is_unverified_and_not_signalled(self) -> None:
        root = Path('/repo'); home = root / '.test/android-build/gradle-home-public'
        with mock.patch.object(android, 'run', return_value=''), \
                mock.patch.object(android, 'owned_gradle_processes', return_value={}), \
                mock.patch.object(android, 'task_gradle_candidates', return_value=[123], create=True), \
                mock.patch.object(android.os, 'kill') as kill:
            result = android.cleanup_gradle(root, home, {}, android.time.monotonic()+30)
        self.assertFalse(result['verified'])
        kill.assert_not_called()

    def test_candidate_scan_initial_or_final_failure_never_claims_cleanup(self) -> None:
        root = Path('/repo'); home = root / '.test/android-build/gradle-home-public'
        for effects in ([RuntimeError('PUBLIC_ENUMERATION_FAILED')], [[], RuntimeError('PUBLIC_ENUMERATION_FAILED')]):
            with mock.patch.object(android, 'run', return_value=''), \
                    mock.patch.object(android, 'owned_gradle_processes', return_value={}), \
                    mock.patch.object(android, 'task_gradle_candidates', side_effect=effects), \
                    mock.patch.object(android.os, 'kill') as kill:
                result = android.cleanup_gradle(root, home, {}, android.time.monotonic()+30)
            self.assertFalse(result['verified']); kill.assert_not_called()
            self.assertNotIn('PUBLIC_ENUMERATION_FAILED', json.dumps(result))

    def test_cleanup_pid_reuse_is_not_signalled_and_late_exit_is_waited(self) -> None:
        root, home = Path('/repo'), Path('/repo/.test/android-build/gradle-home-unique')
        old = android.OwnedProcess('OLD_START', Path('/public/java'), 'a' * 64, 'b' * 64)
        new = android.OwnedProcess('NEW_START', Path('/public/java'), 'a' * 64, 'b' * 64)
        for reused in (False, True):
            clock = [0.0]; killed_at = [None]; queries = [0]; signals = []
            def owned(*args, **kwargs):
                queries[0] += 1
                if reused and queries[0] >= 2:
                    return {123: new}
                if killed_at[0] is not None and clock[0] - killed_at[0] >= 0.6:
                    return {}
                return {123: old}
            def started(*args):
                if reused and queries[0] >= 2: return 'NEW_START'
                if killed_at[0] is not None and clock[0] - killed_at[0] >= 0.6: return ''
                return 'OLD_START'
            def kill(pid, action):
                signals.append(action)
                if action == android.signal.SIGKILL: killed_at[0] = clock[0]
            def sleep(seconds): clock[0] += seconds
            with mock.patch.object(android, 'run', return_value=''), \
                    mock.patch.object(android, 'owned_gradle_processes', side_effect=owned), \
                    mock.patch.object(android, 'process_start_time', side_effect=started), \
                    mock.patch.object(android.time, 'monotonic', side_effect=lambda: clock[0]), \
                    mock.patch.object(android.time, 'sleep', side_effect=sleep), \
                    mock.patch.object(android.os, 'kill', side_effect=kill):
                result = android.cleanup_gradle(root, home, {}, 100)
            if reused:
                self.assertFalse(result['verified']); self.assertEqual(signals, [])
            else:
                self.assertTrue(result['verified'])
                self.assertEqual(signals, [android.signal.SIGTERM, android.signal.SIGKILL])
                self.assertGreaterEqual(clock[0] - killed_at[0], 0.6)
            self.assertLessEqual(clock[0], android.CLEANUP_RESERVE_SECONDS)

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

    def test_distribution_seed_follows_tls_and_precedes_gradle_without_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); self.create_locks(root); order = []
            def run(argv, *args, **kwargs):
                if 'help' in argv:
                    order.append('help'); return 'BETTBOX_TASK_DNS_VERIFIED\n'
                order.append('tls'); return 'OFFICIAL_TLS plugins.gradle.org 200\n'
            def seed(*args):
                order.append('seed')
                self.assertEqual(args[0], root)
                self.assertTrue(args[1].is_relative_to(root / '.test/android-build'))
                self.assertIsInstance(args[2], float)
                return {'reused': True, 'source': 'project-task-gradle-home'}
            with mock.patch.object(android, 'run', side_effect=run), \
                    mock.patch.object(android, 'source_snapshot', return_value={'head': 'abc'}), \
                    mock.patch.object(android, 'authorize_execution', return_value='a'*64), \
                    mock.patch.object(android, 'cleanup_gradle', return_value={'verified': True}), \
                    mock.patch.object(android.distribution_cache, 'seed_distribution_zip', side_effect=seed):
                android.execute(root, {}, self.environment(), network_check_only=True)
            self.assertEqual(order, ['tls', 'seed', 'help'])
            receipt = json.loads((root / '.test/android-build/receipt.json').read_text())
            self.assertTrue(receipt['distribution_zip']['reused'])

    def test_primary_help_failure_survives_secondary_cleanup_network_and_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); self.create_locks(root)
            primary = android.CommandFailed('gradlew', 1, 'java.net.UnknownHostException: jitpack.io')
            help_failed = [False]
            def fake_run(argv, cwd, env, **kwargs):
                if 'help' in argv:
                    help_failed[0] = True
                    (root / android.LOCK_FILES[0]).write_text('PUBLIC_LOCK_DRIFT')
                    raise primary
                return 'OFFICIAL_TLS plugins.gradle.org 200\n'
            def lease_check():
                if help_failed[0]:
                    raise android.dependency_network.NetworkError('PUBLIC_UNKNOWN_DETAIL')
            self.lease.check.side_effect = lease_check
            self.lease.close.side_effect = RuntimeError('PUBLIC_FAKE_SECRET_NOT_FOR_RECEIPT')
            versions = {'JavaExecutablePath': '/PUBLIC/Android Studio.app/bin/java', 'JavaExecutableSHA256': 'a' * 64}
            with mock.patch.object(android, 'run', side_effect=fake_run), \
                    mock.patch.object(android, 'source_snapshot', side_effect=lambda *args: {'head': 'changed' if help_failed[0] else 'abc'}), \
                    mock.patch.object(android, 'authorize_execution', return_value='a' * 64), \
                    mock.patch.object(android, 'cleanup_gradle', return_value={'verified': False}) as cleanup:
                with self.assertRaisesRegex(RuntimeError, 'gradlew'):
                    android.execute(root, versions, self.environment(), network_check_only=True)
            receipt = json.loads((root / '.test/android-build/receipt.json').read_text())
            self.assertEqual(receipt['failure_reason'], str(primary))
            self.assertEqual(receipt['safe_failure_summary'], primary.summary)
            self.assertEqual(receipt['status'], 'failed')
            self.assertEqual(set(receipt['secondary_failures']), {
                '最终任务 DNS 租约复核失败', '任务 DNS 刷新线程退出证据不足',
                '独立 Gradle daemon/worker 终止证据不足', '最终依赖锁定文件检查发现漂移',
                '最终源码输入检查发现漂移或无法完成复核'})
            self.assertNotIn('PUBLIC_FAKE_SECRET', json.dumps(receipt))
            binding = cleanup.call_args.kwargs['java_identity']
            self.assertEqual(binding.executable, Path(versions['JavaExecutablePath']))
            self.assertEqual(binding.sha256, versions['JavaExecutableSHA256'])

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
