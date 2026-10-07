"""隔离验证已修复的 Android 构建缺陷；只使用公开夹具与本机回环。"""
from __future__ import annotations
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

BASELINE = "23747c0a5fd98dfc3f761d98760589ecc84029e2"
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts import android_dependency_network as current_network
from scripts.tests import test_android_dependency_network as network_tests
from scripts.tests import test_build_android as build_tests

def historical(path: str, name: str):
    result = subprocess.run(["git", "show", f"{BASELINE}:{path}"], cwd=ROOT,
                            capture_output=True, timeout=10, check=True)
    module = types.ModuleType(name)
    module.__file__ = str(ROOT / path)
    sys.modules[name] = module
    exec(compile(result.stdout, module.__file__, "exec"), module.__dict__)
    return module

def slow_header(module) -> bool:
    case = network_tests.DependencyNetworkTest("test_slow_header_timeout_is_local_while_authorized_tunnel_stays_usable")
    with mock.patch.object(network_tests, "network", module):
        result = unittest.TextTestRunner(stream=io.StringIO()).run(case)
    # 旧实现必须因实际响应行为失败，不能把缺少新增 API 当作复现。
    if result.errors:
        raise RuntimeError("慢请求头复现存在夹具错误")
    if result.failures and "408 Request Timeout" not in result.failures[0][1]:
        raise RuntimeError("慢请求头失败不符合已定位行为")
    return result.wasSuccessful()

def holder(module, *, current: bool) -> bool:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        home = root / ".test/android-build/gradle-home-regression"; home.mkdir(parents=True)
        java = root / "Android Studio.app/Contents/jbr/bin/java"
        java.parent.mkdir(parents=True); java.write_bytes(b"PUBLIC_JAVA_FIXTURE")
        stamp = "Wed Oct  7 10:00:00 2026"
        main = "org.gradle.launcher.daemon.bootstrap.GradleDaemon"
        if current:
            raw = f"p123\ncjava\nf7\nn{home}/daemon.log\n"
            with mock.patch.object(module, "run", side_effect=[raw, stamp, stamp]), \
                    mock.patch.object(module, "process_executable", return_value=java.resolve()), \
                    mock.patch.object(module, "process_arguments", return_value=(str(java), f"-Dgradle.user.home={home}", main)):
                result = module.owned_gradle_processes(home, root, {}, time.monotonic()+30,
                             module.JavaIdentity(java.resolve(), module.sha256(java)))
                return 123 in result
        raw = f"p123\ncjava\nn{home}/daemon.log\n"
        command = f"{java} -Dgradle.user.home={home} {main}"
        with mock.patch.object(module, "run", side_effect=[raw, command, stamp]):
            try:
                result = module.owned_gradle_processes(home, root, {}, time.monotonic()+30)
            except RuntimeError as error:
                if str(error) != "独立 Gradle 目录存在无法授权终止的进程":
                    raise
                return False
            return 123 in result

def main() -> int:
    try:
        old_network = historical("scripts/android_dependency_network.py", "historical_android_network")
        old_builder = historical("scripts/build_android.py", "historical_android_builder")
        evidence = {"baseline": BASELINE,
                    "slow_header_before": slow_header(old_network),
                    "slow_header_after": slow_header(current_network),
                    "java_path_spaces_before": holder(old_builder, current=False),
                    "java_path_spaces_after": holder(build_tests.android, current=True),
                    "external_network": False, "process_signals": False}
        passed = (not evidence["slow_header_before"] and evidence["slow_header_after"]
                  and not evidence["java_path_spaces_before"] and evidence["java_path_spaces_after"])
        evidence["verified"] = passed
        print(json.dumps(evidence, ensure_ascii=False))
        return 0 if passed else 1
    except Exception:
        print(json.dumps({"verified": False, "failure": "隔离复现未满足预期"}, ensure_ascii=False))
        return 1
if __name__ == "__main__":
    raise SystemExit(main())
