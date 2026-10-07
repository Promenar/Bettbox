#!/usr/bin/env python3
"""核验本机 Android arm64 工具链，显式 --execute 才生成 debug APK。"""
from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import platform
import plistlib
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence

sys.dont_write_bytecode = True
try:
    from scripts import android_dependency_network as dependency_network
except ModuleNotFoundError:
    import android_dependency_network as dependency_network

try:
    from scripts import android_release_signing as release_signing
except ModuleNotFoundError:
    import android_release_signing as release_signing

FLUTTER_VERSION = "3.44.9"
GO_VERSION = "1.26.5"
NDK_VERSION = "28.2.13676358"
CMAKE_VERSION = "3.22.1"
ABI = "arm64-v8a"
LOCK_FILES = (
    "pubspec.lock", "core/go.mod", "core/go.sum",
    "core/Clash.Meta/go.mod", "core/Clash.Meta/go.sum",
)
CORE_OUTPUT = Path("libclash/android") / ABI
APK_OUTPUT = Path("build/app/outputs/flutter-apk/app-debug.apk")
RELEASE_APK_OUTPUT = Path("build/app/outputs/flutter-apk/app-release.apk")
SIGNING_KEYS = ("BETTBOX_ANDROID_STORE_FILE", "BETTBOX_ANDROID_STORE_PASSWORD",
                "BETTBOX_ANDROID_KEY_ALIAS", "BETTBOX_ANDROID_KEY_PASSWORD")
SIGNING_READ_RESERVE = 30
SIGNATURE_VERIFY_RESERVE = 90
BUILD_BUDGET_SECONDS = 2700
CLEANUP_RESERVE_SECONDS = 45
SOURCE_SCOPE = ("lib", "core", "android", "scripts", "plugins", "assets", "arb",
                "pubspec.yaml", "pubspec.lock", ".pdec/contract.yaml")


@dataclass(frozen=True)
class Command:
    argv: tuple[str, ...]
    cwd: Path
    env: Mapping[str, str]


def safe_failure_summary(output: str) -> dict[str, list[str]]:
    """仅抽取预定义公开字段，未知日志不作为诊断摘要返回。"""
    result: dict[str, list[str]] = {"categories": [], "tasks": [], "dependencies": [], "locations": [], "unknown_hosts": [], "exceptions": []}
    forbidden = re.compile(r"secret|token|password|auth|cookie|credential|private.?key|api.?key|bearer", re.I)
    long_value = re.compile(r"[A-Za-z0-9+/=_-]{40,}")
    email = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")
    categories = (
        (r"could not (?:resolve|find)|failed to resolve|dependency resolution|resolution failed", "依赖解析失败"),
        (r"compilation (?:error|failed)|compiler|kernel_snapshot.*failed|error:|failed to compile", "编译失败"),
        (r"(?:signing|signer|keystore).*(?:failed|error|invalid|not found|missing)|(?:failed|error).*(?:signing|signer|keystore)", "签名配置失败"),
        (r"SDK location not found|(?:SDK|NDK|CMake).*(?:error|failed|missing|not found|not installed|not configured|unsuccessful)|platform.*not installed", "SDK或原生工具链失败"),
        (r"官方.*(?:TLS|DNS).*失败|SSLHandshakeException|PKIX.*failed", "官方 TLS 或 DNS 探测失败"),
    )

    # 固定门禁文案来自任务代理和生成的 JVM 校验脚本，不返回任意错误正文。
    guards = (
        "任务 HTTP 与 HTTPS 代理未注入实际 Gradle JVM", "任务代理禁止绕过策略未生效",
        "任务 DNS 映射未注入实际 Gradle JVM", "任务 DNS 缓存策略未生效", "未知主机未被拒绝",
        "任务代理选择失败", "任务代理地址失败", "入口范围失败", "任务 DNS 缓存策略失败",
        "DNS 闭包失败", "官方主机直接解析未被拒绝", "本机 localhost 解析越出回环", "官方 TLS 探测 HTTP 失败", "官方重定向次数超限",
        "官方 Java TLS 或 DNS 边界探测失败", "任务代理失败、取消或时间预算耗尽",
        "任务代理启动失败", "任务 DoH 子进程退出未验证", "DoH 查询绝对时间预算耗尽",
        "批准 DoH 子进程查询失败", "批准 DoH 入口解析或默认 TLS 请求失败",
        "CONNECT 目标越出批准范围", "CONNECT 请求头超出范围", "CONNECT 请求头格式拒绝",
        "CONNECT 请求头时间预算耗尽", "官方地址在有界解析与连接期间不可用",
        "任务代理连接总量预算耗尽", "DoH 连接记录无效", "任务代理端口无效",
        "项目 Gradle JVM 参数不符合任务网络注入契约",
    )
    public_exceptions = (
        "org.gradle.api.GradleException", "org.gradle.api.GradleScriptException",
        "org.gradle.internal.exceptions.LocationAwareException",
        "org.codehaus.groovy.control.MultipleCompilationErrorsException",
        "groovy.lang.MissingPropertyException", "groovy.lang.MissingMethodException",
        "java.lang.IllegalStateException", "java.lang.IllegalArgumentException",
        "java.lang.ClassNotFoundException", "java.lang.NoClassDefFoundError",
        "java.lang.NullPointerException", "java.lang.UnsupportedOperationException",
        "java.net.UnknownHostException", "javax.net.ssl.SSLHandshakeException",
    )
    public_files = ("task-network.gradle", "DependencyProbe.java", "settings.gradle.kts",
                    "build.gradle.kts", "gradle.properties", "gradle-wrapper.properties")

    def add(key: str, value: str, limit: int = 4) -> None:
        if sum(map(len, result.values())) < 8 and len(result[key]) < limit and value not in result[key]:
            result[key].append(value)

    # 日志再长也只扫描有限字符；绝不返回原始行、命令、环境或任意引号值。
    for line in output[-65536:].splitlines():
        if len(line) > 2000 or forbidden.search(line) or email.search(line):
            continue
        if re.search(r"https?://[^\s]*[?@]", line, re.I):
            continue
        projected = line
        exceptions = [name for name in public_exceptions if re.search(r"(?<![\w.$])" + re.escape(name) + r"(?![\w.$])", line)]
        for name in exceptions:
            projected = projected.replace(name, '')
        # 只投影严格完整的 Gradle 来源标题；绝对前缀不进入结果或通用日志通道。
        source = re.fullmatch(r"\s*(?:Initialization script|Build file|Settings file) ['\"]([^'\"\r\n]{1,1024})['\"] line: (\d{1,7})\s*", line)
        location = None
        if source:
            basename = source[1].replace('\\', '/').rsplit('/', 1)[-1]
            if basename in public_files:
                location = basename + ':' + source[2]
                projected = basename + ':' + source[2]
        if long_value.search(projected):
            continue
        if location:
            add("locations", location)
        for name in exceptions:
            add("exceptions", name)
        for message in guards:
            if message in line:
                add("categories", message)
        for host in dependency_network.unknown_hosts(line):
            add("unknown_hosts", host)
            add("categories", "未知依赖主机，停止网络步骤")
        for pattern, label in categories:
            if re.search(pattern, line, re.I):
                add("categories", label)
        task = re.search(r"(?:Execution failed for task|Task)\s+['\"]?(:[A-Za-z][A-Za-z0-9_:.-]{0,119})", line)
        if task:
            add("tasks", task.group(1))
        coordinate = re.search(r"(?:Could not (?:resolve|find)|Failed to resolve)\s+([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+):([a-zA-Z][a-zA-Z0-9_.-]{0,63}):([0-9][a-zA-Z0-9_.+-]{0,31})\b", line)
        if coordinate:
            add("dependencies", ":".join(coordinate.groups()))
        # 仅允许项目代码根下的常见源码扩展与数字行列，丢弃绝对目录前缀。
        for match in re.finditer(r"\b((?:lib|android|core|plugins)/[A-Za-z0-9_./-]{1,160}\.(?:dart|kt|java|cpp|h|kts)):(\d{1,7})(?::(\d{1,7}))?", line):
            location, row, column = match.groups()
            if ".." not in location.split("/"):
                add("locations", f"{location}:{row}" + (f":{column}" if column else ""))
    if not any(result.values()):
        result["categories"] = ["错误未匹配安全公开诊断字段"]
    return result


class CommandFailed(RuntimeError):
    def __init__(self, tool: str, code: int, output: str):
        self.summary = safe_failure_summary(output)
        super().__init__(f"工具执行失败：{tool}，退出码 {code}；安全摘要：" +
                         json.dumps(self.summary, ensure_ascii=False))


def build_environment(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    # 不继承令牌、签名配置、任意 GOFLAGS 或其它不属于构建契约的环境项。
    allowed = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "JAVA_HOME",
               "ANDROID_HOME", "ANDROID_SDK_ROOT", "PUB_CACHE", "GOPATH", "GOCACHE", "XDG_CONFIG_HOME")
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    env.update({"GOTOOLCHAIN": "local", "GOWORK": "off"})
    if extra:
        env.update(extra)
    return env


def run(argv: Sequence[str], root: Path, env: Mapping[str, str], *, timeout: float = 120,
        allowed_returncodes: tuple[int, ...] = (0,),
        network_lease: dependency_network.NetworkLease | None = None,
        sensitive_output: bool = False) -> str:
    if network_lease is not None:
        network_lease.check()
    process = subprocess.Popen(argv, cwd=root, env=dict(env), text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        if network_lease is None:
            output, _ = process.communicate(timeout=timeout)
        else:
            end = time.monotonic() + timeout
            while True:
                network_lease.check()
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(argv, timeout)
                try:
                    output, _ = process.communicate(timeout=min(1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
            network_lease.check()
    except (subprocess.TimeoutExpired, dependency_network.NetworkError) as error:
        # 编译器与 Gradle 子进程属于同一会话，超时一并终止，避免后台继续写入产物。
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            if process.stdout is not None:
                process.stdout.close()
        if isinstance(error, dependency_network.NetworkError):
            raise error from None
        raise RuntimeError(f"工具执行超时：{Path(argv[0]).name}") from None
    if sensitive_output:
        # 正式签名子进程的正文不解析、不返回，也不进入通用诊断摘要。
        if process.returncode not in allowed_returncodes:
            raise RuntimeError("正式 APK 构建失败，工具正文已丢弃")
        return ""
    if process.returncode not in allowed_returncodes:
        # 原始子进程日志可能包含路径或第三方敏感信息，不回显或写入回执。
        raise CommandFailed(Path(argv[0]).name, process.returncode, output)
    if network_lease is not None and dependency_network.unknown_hosts(output):
        raise CommandFailed(Path(argv[0]).name, 1, output)
    return output


@dataclass(frozen=True)
class JavaIdentity:
    executable: Path
    sha256: str


@dataclass(frozen=True)
class OwnedProcess:
    started: str
    executable: Path
    executable_sha256: str
    argv_sha256: str


def process_executable(pid: int) -> Path:
    """从 macOS 内核取真实 executable，不信任 argv0 或 ps 空格文本。"""
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)  # SDK：4 * MAXPATHLEN。
    try:
        if function(pid, buffer, len(buffer)) <= 0:
            if ctypes.get_errno() == errno.ESRCH:
                raise ProcessLookupError("进程已退出")
            raise RuntimeError("无法核验内核进程入口")
        value = buffer.value.decode("utf-8", errors="strict")
        if not value or not Path(value).is_absolute():
            raise RuntimeError("内核进程入口格式拒绝")
        return Path(value).resolve(strict=True)
    except ProcessLookupError:
        raise
    except (OSError, UnicodeError):
        raise RuntimeError("无法核验内核进程入口") from None
    finally:
        ctypes.memset(ctypes.addressof(buffer), 0, ctypes.sizeof(buffer))


def decode_process_argv(buffer: ctypes.Array, size: int) -> tuple[str, ...]:
    """只解码 argc 限定 argv；不得复制、解析或记录其后的环境区。"""
    if not 5 <= size <= 1048576:
        raise RuntimeError("内核参数范围拒绝")
    argc = struct.unpack_from("=i", buffer, 0)[0]
    if not 1 <= argc <= 4096:
        raise RuntimeError("内核参数范围拒绝")
    position = 4
    # 跳过内核 executable 文本，不转换整个 buffer。
    while position < size and buffer[position] != b"\0":
        position += 1
    if position >= size or position - 4 > 4096:
        raise RuntimeError("内核参数范围拒绝")
    while position < size and buffer[position] == b"\0":
        position += 1
    arguments = []
    for _ in range(argc):
        start = position
        while position < size and buffer[position] != b"\0":
            position += 1
        if position >= size or position - start > 32768:
            raise RuntimeError("内核参数范围拒绝")
        try:
            arguments.append(bytes(buffer[start:position]).decode("utf-8", errors="strict"))
        except UnicodeError:
            raise RuntimeError("内核参数编码拒绝") from None
        position += 1
    return tuple(arguments)


def process_arguments(pid: int) -> tuple[str, ...]:
    """KERN_PROCARGS2 含环境尾部，原缓冲在 finally 清零。"""
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    function = library.sysctl
    function.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                         ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    function.restype = ctypes.c_int
    mib = (ctypes.c_int * 3)(1, 49, pid)  # 公开 SDK：CTL_KERN / KERN_PROCARGS2。
    size = ctypes.c_size_t()
    def query(output) -> None:
        if function(mib, 3, output, ctypes.byref(size), None, 0) != 0:
            if ctypes.get_errno() == errno.ESRCH:
                raise ProcessLookupError("进程已退出")
            raise RuntimeError("无法核验内核进程参数")
    query(None)
    if not 5 <= size.value <= 1048576:
        raise RuntimeError("内核参数范围拒绝")
    buffer = ctypes.create_string_buffer(size.value)
    try:
        query(buffer)
        if size.value > ctypes.sizeof(buffer):
            raise RuntimeError("内核参数范围拒绝")
        return decode_process_argv(buffer, size.value)
    finally:
        ctypes.memset(ctypes.addressof(buffer), 0, ctypes.sizeof(buffer))


def java_main_class(arguments: tuple[str, ...]) -> str | None:
    # 只允许真实主类，不接受藏在 property/classpath/程序参数里的同名字符串。
    values = {"-cp", "-classpath", "--class-path", "-p", "--module-path",
              "--upgrade-module-path", "--add-opens", "--add-exports", "--add-modules",
              "--limit-modules", "--patch-module", "--enable-native-access"}
    index = 1
    while index < len(arguments):
        argument = arguments[index]
        if argument in ("-jar", "-m", "--module"):
            return None
        if argument in values:
            index += 2
            continue
        if argument == "--":
            return arguments[index + 1] if index + 1 < len(arguments) else None
        if argument.startswith("-"):
            index += 1
            continue
        return argument
    return None


def argv_owns_home(arguments: tuple[str, ...], home: Path) -> bool:
    for argument in arguments[1:]:
        if argument.startswith("-Dgradle.user.home="):
            value = Path(argument.split("=", 1)[1])
            if value.is_absolute() and value.resolve() == home:
                return True
    # worker/Kotlin 的 classpath 必须有本任务 home 下实际文件参数；不匹配子串。
    for index, argument in enumerate(arguments[:-1]):
        if argument in ("-cp", "-classpath", "--class-path"):
            for item in arguments[index + 1].split(os.pathsep):
                candidate = Path(item)
                if candidate.is_absolute() and candidate.resolve().is_relative_to(home) and candidate.is_file():
                    return True
    return False


def process_start_time(pid: int, root: Path, env: Mapping[str, str], deadline: float) -> str:
    value = run(("ps", "-p", str(pid), "-o", "lstart="), root, {**env, "LC_ALL": "C"},
                timeout=min(5, remaining_budget(deadline)), allowed_returncodes=(0, 1)).strip()
    if value and not re.fullmatch(r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+"
            r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+"
            r"[0-9]{1,2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2}\s+[0-9]{4}", value):
        raise RuntimeError("PID 起始时间证据格式拒绝")
    return value


def owned_gradle_processes(home: Path, root: Path, env: Mapping[str, str], deadline: float,
                           java_identity: JavaIdentity | None = None) -> dict[int, OwnedProcess]:
    if home.is_symlink():
        raise RuntimeError("独立 Gradle 目录边界拒绝")
    home = home.resolve()
    if not home.is_relative_to(root.resolve() / ".test/android-build") or not home.name.startswith("gradle-home-"):
        raise RuntimeError("独立 Gradle 目录边界拒绝")
    raw = run(("lsof", "-nP", "-Fpcfn", "+D", str(home)), root, env,
              timeout=min(10, remaining_budget(deadline)), allowed_returncodes=(0, 1))
    if len(raw) > 1048576:
        raise RuntimeError("独立目录归属证据范围拒绝")
    holders: dict[int, list[str]] = {}
    pid, descriptor = None, None
    for line in raw.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid, descriptor = int(line[1:]), None
        elif line.startswith("f"):
            descriptor = line[1:] if line[1:].isdigit() else None
        elif line.startswith("n") and pid is not None and descriptor is not None:
            holders.setdefault(pid, []).append(line[1:])
        elif not line.startswith(("c", "n")):
            raise RuntimeError("无法可靠解析独立 Gradle 目录的进程归属证据")
    if not holders:
        return {}
    if java_identity is None or not re.fullmatch(r"[0-9a-f]{64}", java_identity.sha256):
        raise RuntimeError("缺少预检选定 Java 的入口摘要绑定")
    selected = java_identity.executable.resolve(strict=True)
    if sha256(selected) != java_identity.sha256:
        raise RuntimeError("预检 Java 入口摘要变化")
    allowed = {"org.gradle.launcher.daemon.bootstrap.GradleDaemon",
               "org.gradle.process.internal.worker.GradleWorkerMain",
               "worker.org.gradle.process.internal.worker.GradleWorkerMain",
               "org.jetbrains.kotlin.daemon.KotlinCompileDaemon"}
    verified = {}
    for pid, paths in holders.items():
        remaining_budget(deadline)
        if pid <= 0 or not any(Path(path).resolve().is_relative_to(home) for path in paths):
            raise RuntimeError("目录持有者缺少实际文件描述符归属证据")
        started = process_start_time(pid, root, env, deadline)
        if not started:
            continue
        try:
            executable = process_executable(pid)
            arguments = process_arguments(pid)
        except ProcessLookupError:
            continue
        if executable != selected or sha256(executable) != java_identity.sha256 or                 java_main_class(arguments) not in allowed or not argv_owns_home(arguments, home):
            raise RuntimeError("独立 Gradle 目录存在无法授权终止的进程")
        if process_start_time(pid, root, env, deadline) != started:
            continue
        verified[pid] = OwnedProcess(started, executable, java_identity.sha256,
            hashlib.sha256(json.dumps(arguments, ensure_ascii=False).encode()).hexdigest())
    return verified


def task_gradle_candidates(home: Path, root: Path, env: Mapping[str, str], deadline: float,
                           java_identity: JavaIdentity | None = None) -> list[int]:
    """补查已关闭目录 FD 的任务 JVM；此证据仅阻断成功，不授权发送信号。"""
    raw = run(("ps", "-axo", "pid=,uid="), root, env,
              timeout=min(5, remaining_budget(deadline)))
    lines = raw.splitlines()
    if len(raw) > 1048576 or len(lines) > 16384:
        raise RuntimeError("进程候选枚举范围拒绝")
    pids = []
    for line in lines:
        fields = line.split()
        if len(fields) != 2 or not all(value.isdigit() for value in fields):
            raise RuntimeError("进程候选枚举格式拒绝")
        pid, uid = map(int, fields)
        if pid <= 0:
            raise RuntimeError("进程候选枚举格式拒绝")
        if uid == os.getuid():
            pids.append(pid)
    if not pids:
        return []
    if java_identity is None:
        raise RuntimeError("缺少候选 Java 摘要绑定")
    selected = java_identity.executable.resolve(strict=True)
    if sha256(selected) != java_identity.sha256:
        raise RuntimeError("候选 Java 入口摘要变化")
    allowed = {"org.gradle.launcher.daemon.bootstrap.GradleDaemon",
               "org.gradle.process.internal.worker.GradleWorkerMain",
               "worker.org.gradle.process.internal.worker.GradleWorkerMain",
               "org.jetbrains.kotlin.daemon.KotlinCompileDaemon"}
    candidates = []
    for pid in pids:
        remaining_budget(deadline)
        try:
            if process_executable(pid) != selected:
                continue
            arguments = process_arguments(pid)
        except ProcessLookupError:
            continue
        if java_main_class(arguments) in allowed and argv_owns_home(arguments, home.resolve()):
            candidates.append(pid)
    return candidates


def cleanup_gradle(root: Path, home: Path, env: Mapping[str, str], deadline: float,
                   java_identity: JavaIdentity | None = None) -> dict[str, object]:
    evidence: dict[str, object] = {"verified": False, "stop_scope": str(home), "terminated_pids": []}
    # 清理最多45秒，且总体期限内为最后源码复核保留5秒。
    end = min(deadline - 5, time.monotonic() + CLEANUP_RESERVE_SECONDS)
    def owned() -> dict[int, OwnedProcess]:
        return owned_gradle_processes(home, root, env, end, java_identity)
    def surviving(known: Mapping[int, OwnedProcess]) -> list[int]:
        return [pid for pid, identity in known.items()
                if process_start_time(pid, root, env, end) == identity.started]
    try:
        known = owned()
        initial_candidates = task_gradle_candidates(home, root, env, end, java_identity)
        evidence["initial_unbound_task_pids"] = [pid for pid in initial_candidates if pid not in known]
        try:
            run((str(root / "android/gradlew"), "--stop", "--gradle-user-home", str(home),
                 "-Dorg.gradle.daemon=false"), root / "android", env,
                timeout=min(15, remaining_budget(end)))
            evidence["stop_command_passed"] = True
        except RuntimeError:
            evidence["stop_command_passed"] = False
        for pid, identity in owned().items():
            # 同 PID 新身份不能覆盖停止前证据，避免把复用进程纳入终止授权。
            known.setdefault(pid, identity)
        evidence["observed_owned_pids"] = list(known)
        for pid, identity in known.items():
            if owned().get(pid) != identity:
                continue
            try:
                os.kill(pid, signal.SIGTERM)
                evidence["terminated_pids"].append(pid)
            except ProcessLookupError:
                pass
        until = min(end, time.monotonic() + 5)
        while time.monotonic() < until and (owned() or surviving(known)):
            time.sleep(min(0.2, remaining_budget(end)))
        current = owned()
        for pid, identity in current.items():
            # SIGKILL 前重新核验全部证据，而非复用首次 argv 或仅看进程名。
            if known.get(pid) != identity or owned().get(pid) != identity:
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # SIGKILL 不是退出证据：有界等待内核实际回收，同 PID 新代次不算原进程。
        until = min(end, time.monotonic() + 5)
        while True:
            current, alive = owned(), surviving(known)
            if not current and not alive or time.monotonic() >= until:
                break
            time.sleep(min(0.2, remaining_budget(end)))
        candidates = task_gradle_candidates(home, root, env, end, java_identity)
        evidence.update({"remaining_owned_pids": list(current), "surviving_verified_pids": alive,
                         "remaining_task_candidates": candidates,
                         "verified": not current and not alive and not candidates,
                         "method": "owned文件描述符、内核Java入口及预检摘要、精确主类/目录参数、PID起始时间和退出检查"})
    except Exception:
        evidence["failure_reason"] = "无法完成独立 Gradle 进程的终止归属复核"
    return evidence


def remaining_budget(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("Android 构建总体时间预算已耗尽")
    return remaining


def authorize_execution(root: Path, validator: Path | None, env: Mapping[str, str], deadline: float, *, release: bool = False) -> str:
    if validator is None or not validator.is_file():
        raise RuntimeError("执行前必须通过 --framework-validator 或 BETTBOX_PDEC_VALIDATOR 指定统一 PDEC 验证器")
    project_validator = root / "scripts/validate_android_contract.py"
    validator_argv = (sys.executable, str(project_validator), "--framework-validator", str(validator))
    if release:
        validator_argv += ("--release",)
    raw = run(validator_argv,
              root, env, timeout=min(120, remaining_budget(deadline)))
    result = json.loads(raw)
    framework = result.get("framework", {})
    contract = json.loads((root / ".pdec/contract.yaml").read_text())
    approved = contract.get("approval", {}).get("contract_digest")
    digest = framework.get("contract_digest")
    if result.get("execution_ready") is not True or framework.get("execution_ready") is not True or \
            not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or digest != approved:
        raise RuntimeError("项目 Android 扩展或统一 PDEC 未获当前摘要批准")
    operation = result.get("release_operation" if release else "android_operation", {})
    if operation.get("timeout_seconds") != BUILD_BUDGET_SECONDS:
        raise RuntimeError("Android 契约时间预算与构建入口不一致")
    if release:
        expected = {"executor": "local-mac", "target_os": "android", "target_arch": "arm64",
                    "argv": ["python3", "scripts/build_android.py", "--execute", "--release"],
                    "cwd": ".", "timeout_seconds": BUILD_BUDGET_SECONDS,
                    "artifacts": [RELEASE_APK_OUTPUT.as_posix()]}
        if operation != contract.get("platform_extensions", {}).get("android_release") or any(
                operation.get(key) != value for key, value in expected.items()):
            raise RuntimeError("正式 APK 构建扩展未获当前 PDEC 契约批准")
    return digest


def source_snapshot(root: Path, env: Mapping[str, str], deadline: float) -> dict[str, object]:
    def git(args: Sequence[str], cwd: Path = root) -> str:
        return run(("git", *args), cwd, env, timeout=min(120, remaining_budget(deadline)))

    head = git(("rev-parse", "HEAD")).strip()
    status = git(("status", "--porcelain=v1", "--untracked-files=all", "--", *SOURCE_SCOPE))
    files = git(("ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", *SOURCE_SCOPE)).split("\0")
    # gitlink 本身不承载源文件；把其实际工作树中的输入一起计入摘要。
    expanded = []
    for name in filter(None, files):
        path = root / name
        if path.is_dir():
            nested = git(("ls-files", "--cached", "--others", "--exclude-standard", "-z"), path)
            expanded.extend(f"{name}/{entry}" for entry in nested.split("\0") if entry)
        else:
            expanded.append(name)
    hashes = {}
    for name in sorted(set(expanded)):
        remaining_budget(deadline)
        path = root / name
        # 不读取秘密文件，也不追踪可能指向仓库外的符号链接内容。
        if path.name.startswith(".env") or path.name == "local.properties" or \
                path.suffix.lower() in (".jks", ".keystore", ".pem", ".key", ".p12", ".pfx"):
            continue
        if path.is_symlink():
            raise RuntimeError(f"源码输入包含未授权的符号链接：{name}")
        hashes[name] = sha256(path) if path.is_file() else None
    return {"head": head, "dirty": bool(status.strip()),
            "status_sha256": hashlib.sha256(status.encode()).hexdigest(),
            "source_sha256": hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
            "source_file_count": len(hashes)}


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def snapshot_locks(root: Path) -> dict[str, str]:
    for name in LOCK_FILES:
        if not (root / name).is_file():
            raise RuntimeError(f"缺少依赖锁定文件：{name}")
    return {name: sha256(root / name) for name in LOCK_FILES}


def changed_locks(root: Path, before: Mapping[str, str]) -> list[str]:
    return [name for name, digest in before.items()
            if not (root / name).is_file() or sha256(root / name) != digest]


def parse_flutter_version(raw: str) -> str:
    decoder = json.JSONDecoder()
    versions = []
    for match in re.finditer(r"\{", raw):
        try:
            value, _ = decoder.raw_decode(raw, match.start())
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and isinstance(value.get("frameworkVersion"), str):
            versions.append(value["frameworkVersion"])
    if len(versions) != 1:
        raise RuntimeError("无法解析唯一的 Flutter 版本")
    return versions[0]


def studio_candidates(bases: tuple[Path, ...], deadline: float | None,
                      *, entry_budget: int = 100000) -> set[Path]:
    """与 Flutter macOS 搜索一致：普通目录递归、不跟随链接、遇 app 停止。"""
    end = min(deadline if deadline is not None else float('inf'), time.monotonic() + 30)
    remaining = entry_budget
    candidates: set[Path] = set()
    pending = list(bases)
    while pending:
        remaining_budget(end)
        current = pending.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    remaining_budget(end)
                    remaining -= 1
                    if remaining < 0:
                        raise RuntimeError("Android Studio 安装搜索条目预算耗尽")
                    if not entry.is_dir(follow_symlinks=False):
                        continue
                    path = Path(entry.path)
                    if entry.name.endswith('.app'):
                        if entry.name.startswith('Android Studio'):
                            candidates.add(path)
                    else:
                        pending.append(path)
        except OSError:
            # SDK 对不可读取或消失的目录跳过；不读取私有内容，也不输出路径。
            continue
    return candidates


def selected_java(flutter: Path, root: Path, env: Mapping[str, str], deadline: float | None) -> tuple[Path, str]:
    """按已核验 Flutter Java.find 优先级选 JDK，不运行会联网的 doctor。"""
    sdk = flutter.resolve().parent.parent
    source = (sdk / "packages/flutter_tools/lib/src/android/java.dart").read_text()
    selection = source[source.index('_JavaHomePathWithSource? _findJavaHome('):]
    if not selection.index("config.getValue('jdk-dir')") < selection.index('androidStudio?.javaPath') < selection.index('platform.environment[Java.javaHomeEnvironmentVariable]'):
        raise RuntimeError("当前 Flutter JDK 选择源码不符合已核验契约")
    home = Path(env.get('HOME', '.'))
    legacy = home / '.flutter_settings'
    settings = legacy if legacy.is_file() else Path(env.get('XDG_CONFIG_HOME', str(home / '.config/flutter'))) / 'settings'
    try:
        values = json.loads(settings.read_text()) if settings.is_file() else {}
        configured, studio = values.get('jdk-dir'), values.get('android-studio-dir')
    except (OSError, ValueError, AttributeError):
        raise RuntimeError("无法抽取 Flutter 非秘密 JDK 配置字段") from None
    if configured is not None:
        if not isinstance(configured, str) or not Path(configured).is_absolute():
            raise RuntimeError("Flutter jdk-dir 无效")
        return Path(configured) / 'bin/java', 'flutterConfig'
    candidates: set[Path] = set()
    if studio is not None:
        if not isinstance(studio, str) or not Path(studio).is_absolute():
            raise RuntimeError("Flutter Android Studio 路径无效")
        candidates.add(Path(studio).parent if Path(studio).name == 'Contents' else Path(studio))
    else:
        # 与 SDK 的 macOS 查找入口一致；安装歧义拒绝猜测，不写用户配置。
        candidates.update(studio_candidates((Path('/Applications'), home / 'Applications'), deadline))
        raw = run(('mdfind', 'kMDItemCFBundleIdentifier="com.google.android.studio*"'), root, env,
                  timeout=min(10, remaining_budget(deadline)) if deadline else 10)
        if len(raw.splitlines()) > 64:
            raise RuntimeError("Android Studio 安装候选过多")
        candidates.update(Path(line) for line in raw.splitlines() if line)
    valid = []
    for bundle in candidates:
        try:
            with (bundle / 'Contents/Info.plist').open('rb') as stream:
                metadata = plistlib.load(stream)
            if 'JetBrainsToolboxApp' in metadata:
                continue
            match = re.match(r'([0-9]+)(?:\.([0-9]+))?', metadata.get('CFBundleShortVersionString', ''))
            if match is None or int(match.group(1)) < 2022:
                raise RuntimeError("Android Studio 版本不符合当前已核验 JBR 选择契约")
            java = bundle / 'Contents/jbr/Contents/Home/bin/java'
            if java.is_file():
                run((str(java), '-version'), root, env, timeout=min(10, remaining_budget(deadline)) if deadline else 10)
                valid.append(java)
        except (OSError, ValueError):
            raise RuntimeError("Android Studio 公开版本元数据无法核验") from None
    if len(valid) > 1:
        raise RuntimeError("Android Studio JDK 选择存在歧义，需要明确 Flutter jdk-dir")
    if valid:
        return valid[0], 'androidStudio'
    if env.get('JAVA_HOME'):
        return Path(env['JAVA_HOME']) / 'bin/java', 'javaHome'
    java = shutil.which('java', path=env.get('PATH'))
    if not java:
        raise RuntimeError("无法证明 Flutter 实际 JDK 入口")
    return Path(java).resolve(), 'path'


def preflight(root: Path, sdk: Path, deadline: float | None = None) -> tuple[dict[str, str], dict[str, str]]:
    if platform.system() != "Darwin" or platform.machine() not in ("arm64", "aarch64"):
        raise RuntimeError("此入口只支持 macOS arm64 本机构建")
    env = build_environment({"ANDROID_HOME": str(sdk), "ANDROID_SDK_ROOT": str(sdk)})
    def probe(argv: Sequence[str]) -> str:
        timeout = min(120, remaining_budget(deadline)) if deadline is not None else 120
        return run(argv, root, env, timeout=timeout)
    flutter = shutil.which("flutter", path=env.get("PATH"))
    go = shutil.which("go", path=env.get("PATH"))
    if not flutter or not go:
        raise RuntimeError("缺少 Flutter 或 Go 可执行入口")
    if not shutil.which("lsof", path=env.get("PATH")) or not shutil.which("ps", path=env.get("PATH")):
        raise RuntimeError("缺少独立 Gradle 进程归属与退出核验工具 lsof/ps")
    fv = parse_flutter_version(probe((flutter, "--version", "--machine")))
    match = re.search(r"\bgo(\d+\.\d+\.\d+)\b", probe((go, "version")))
    gv = match.group(1) if match else ""
    if fv != FLUTTER_VERSION or gv != GO_VERSION:
        raise RuntimeError(f"版本不匹配：需要 Flutter {FLUTTER_VERSION}、Go {GO_VERSION}；实际 {fv}、{gv}")
    ndk = sdk / "ndk" / NDK_VERSION
    props = ndk / "source.properties"
    if not props.is_file() or not re.search(
        rf"^Pkg\.Revision\s*=\s*{re.escape(NDK_VERSION)}\s*$", props.read_text(), re.M
    ):
        raise RuntimeError(f"NDK {NDK_VERSION} 未安装或版本元数据不匹配")
    cc = ndk / "toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang"
    cmake = sdk / "cmake" / CMAKE_VERSION / "bin/cmake"
    zipalign = sdk / "build-tools/36.0.0/zipalign"
    for file in (cc, cmake, zipalign, sdk / "platforms/android-36/android.jar", root / "android/gradlew"):
        if not file.is_file():
            raise RuntimeError(f"缺少工具链文件：{file}")
    cmake_raw = probe((str(cmake), "--version"))
    if not re.search(rf"cmake version {re.escape(CMAKE_VERSION)}\b", cmake_raw):
        raise RuntimeError("CMake 版本不匹配")
    clang_raw = probe((str(cc), "--version"))
    java, selection_source = selected_java(Path(flutter), root, env, deadline)
    if not java.is_file():
        raise RuntimeError("Flutter 选中的 Java 入口不存在")
    java_raw = probe((str(java), "-version"))
    jv = re.search(r'(?:openjdk|java) version "(\d+(?:\.[^"\s]+)?)"', java_raw)
    major = int(jv.group(1).split(".")[0]) if jv else 0
    if major < 17:
        raise RuntimeError("Android Gradle Plugin 要求 JDK 17 或更新版本")
    env.update({"JAVA_HOME": str(java.parent.parent), "ANDROID_NDK": str(ndk)})
    versions = {"Flutter": fv, "Go": gv, "NDK": NDK_VERSION, "CMake": CMAKE_VERSION,
                "SDK": "android-36", "BuildTools": "36.0.0", "JDK": jv.group(1), "JDKSelection": selection_source,
                "Clang": clang_raw.splitlines()[0], "JavaExecutablePath": str(java.resolve())}
    for name, file in (("Flutter", Path(flutter)), ("Go", Path(go)), ("Java", java),
                       ("Clang", cc), ("CMake", cmake), ("Zipalign", zipalign)):
        versions[f"{name}ExecutableSHA256"] = sha256(file)
    env.update({"BETTBOX_FLUTTER": flutter, "BETTBOX_GO": go,
                "BETTBOX_CC": str(cc), "BETTBOX_ZIPALIGN": str(zipalign)})
    return versions, env


def command_plan(root: Path, env: Mapping[str, str], core_dir: Path, *, release: bool = False) -> tuple[Command, ...]:
    apk_output = RELEASE_APK_OUTPUT if release else APK_OUTPUT
    core_env = dict(env)
    core_env.update({"GOOS": "android", "GOARCH": "arm64", "CGO_ENABLED": "1",
                     "CC": env["BETTBOX_CC"], "CGO_CFLAGS": "-O3 -Werror"})
    return (
        Command((env["BETTBOX_GO"], "build", "-mod=readonly", "-trimpath",
                 '-ldflags=-w -s -extldflags "-Wl,-z,max-page-size=16384"',
                 "-tags=with_gvisor", "-buildmode=c-shared", "-o", str(core_dir / "libclash.so")),
                root / "core", core_env),
        Command((env["BETTBOX_FLUTTER"], "pub", "get", "--enforce-lockfile"), root, env),
        Command((env["BETTBOX_FLUTTER"], "build", "apk", "--release" if release else "--debug", "--no-pub",
                 "--target-platform", "android-arm64"), root, env),
        Command((env["BETTBOX_ZIPALIGN"], "-c", "-P", "16", "-v", "4", str(root / apk_output)), root, env),
    )


def verify_elf(data: bytes, label: str) -> None:
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise RuntimeError(f"{label} 不是 ELF64 小端核心")
    if struct.unpack_from("<H", data, 18)[0] != 183:
        raise RuntimeError(f"{label} 不是 arm64 ELF")
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    if size < 56 or count == 0 or offset + size * count > len(data):
        raise RuntimeError(f"{label} 的 ELF 段表损坏")
    loads = 0
    for index in range(count):
        pos = offset + index * size
        if struct.unpack_from("<I", data, pos)[0] != 1:
            continue
        loads += 1
        file_offset, address = struct.unpack_from("<QQ", data, pos + 8)
        align = struct.unpack_from("<Q", data, pos + 48)[0]
        if align < 16384 or align & (align - 1) or file_offset % align != address % align:
            raise RuntimeError(f"{label} 的 LOAD 段未满足 16KiB 对齐")
    if not loads:
        raise RuntimeError(f"{label} 缺少可加载段")


def verify_apk(path: Path) -> dict[str, str]:
    with zipfile.ZipFile(path) as archive:
        libraries = [name for name in archive.namelist() if name.startswith("lib/") and name.endswith(".so")]
        if not libraries or any(name.split("/")[1] != ABI for name in libraries):
            raise RuntimeError("APK 原生库为空或包含非 arm64 ABI")
        for required in ("libclash.so", "libcore.so", "libflutter.so"):
            if f"lib/{ABI}/{required}" not in libraries:
                raise RuntimeError(f"APK 缺少 {required}")
        for name in libraries:
            verify_elf(archive.read(name), name)
        return {name: hashlib.sha256(archive.read(name)).hexdigest() for name in libraries}


def execute(root: Path, versions: Mapping[str, str], env: Mapping[str, str],
            framework_validator: Path | None = None, *, deadline: float | None = None,
            network_check_only: bool = False, release: bool = False) -> Path:
    if release and network_check_only:
        raise RuntimeError("正式签名模式不能与仅网络检查组合")
    env = {key: value for key, value in env.items() if key not in SIGNING_KEYS}
    apk_output = RELEASE_APK_OUTPUT if release else APK_OUTPUT
    if deadline is None:
        deadline = time.monotonic() + BUILD_BUDGET_SECONDS
    before = snapshot_locks(root)
    receipt: dict[str, object] = {"started_at": datetime.now(timezone.utc).isoformat(),
        "target": "android-arm64-release" if release else "android-arm64-debug", "toolchain": dict(versions), "locks_before": before,
        "status": "failed", "release_verified": False, "signature_verified": False}
    receipt_dir = root / ".test/android-build"
    receipt_dir.mkdir(parents=True, exist_ok=True)
    receipt_path = receipt_dir / "receipt.json"
    owned_home: Path | None = None
    gradle_started = False
    network_lease = None
    def final_failure(message: str) -> None:
        # 所有调用文案固定；最终门禁失败不替换主要编译/网络/签名失败。
        receipt["status"] = "failed"
        receipt.setdefault("failure_reason", message)
        failures = receipt.setdefault("secondary_failures", [])
        if message not in failures:
            failures.append(message)
    try:
        source_before = source_snapshot(root, env, deadline)
        receipt["source_before"] = source_before
        receipt["approved_contract_digest"] = authorize_execution(root, framework_validator, env, deadline, release=release)
        if source_snapshot(root, env, deadline) != source_before:
            raise RuntimeError("批准检查期间源码输入发生变化")
        owned_home = Path(tempfile.mkdtemp(prefix="gradle-home-", dir=receipt_dir))
        receipt["gradle_user_home"] = str(owned_home.relative_to(root))
        receipt["gradle_daemon_disabled"] = True
        network_lease = dependency_network.NetworkLease(owned_home, deadline - CLEANUP_RESERVE_SECONDS)
        network_lease.start()
        env = dependency_network.jvm_environment(dict(env), owned_home, root / "android/gradle.properties", network_lease.proxy_port)
        probe = dependency_network.prepare_files(owned_home, network_lease.proxy_port)
        def check_inputs() -> None:
            network_lease.check()
            if changed_locks(root, before):
                raise RuntimeError("依赖锁定文件发生变化，停止后续步骤")
            if source_snapshot(root, env, deadline) != source_before:
                raise RuntimeError("源码输入发生变化，停止后续步骤")
        receipt["phase"] = "java-official-tls"
        print("执行网络门禁：Java 默认 TLS 与官方重定向")
        java = str(Path(env["JAVA_HOME"]) / "bin/java")
        java_flags = tuple(shlex.split(env["JAVA_OPTS"]))
        probe_output = run((java, *java_flags, str(probe), *dependency_network.probe_urls(root)),
                           root, env, timeout=min(180, remaining_budget(deadline) - CLEANUP_RESERVE_SECONDS),
                           network_lease=network_lease)
        probe_facts = [{"host": host, "status": int(code)} for host, code in
                       re.findall(r"^OFFICIAL_TLS ([a-z0-9.-]+) ([0-9]{3})$", probe_output, re.M)
                       if host in dependency_network.HOSTS]
        if not probe_facts:
            raise RuntimeError("缺少实际 Java TLS 探测证据")
        receipt["official_tls_probes"] = probe_facts
        check_inputs()
        receipt["phase"] = "gradle-help"
        print("执行依赖门禁：Gradle help")
        gradle_started = True
        help_output = run((str(root / "android/gradlew"), "help", "--no-daemon", "--gradle-user-home", str(owned_home),
                           "-Dorg.gradle.daemon=false"), root / "android", env,
                          timeout=min(600, remaining_budget(deadline) - CLEANUP_RESERVE_SECONDS), network_lease=network_lease)
        if "BETTBOX_TASK_DNS_VERIFIED" not in help_output.splitlines():
            raise RuntimeError("缺少实际 Gradle JVM 网络映射验证证据")
        receipt["gradle_help_verified"] = True
        check_inputs()
        if network_check_only:
            receipt.update({"status": "passed", "target": "android-official-dependency-check"})
        else:
            receipt["phase"] = "android-release-build" if release else "android-debug-build"
            with tempfile.TemporaryDirectory(prefix="core-", dir=receipt_dir) as temp:
                stage = Path(temp)
                plan = command_plan(root, env, stage, release=release)
                for index, command in enumerate(plan):
                    print(f"执行步骤 {index + 1}/{len(plan)}：{Path(command.argv[0]).name}")
                    if index == 2:
                        gradle_started = True
                    reserve = SIGNATURE_VERIFY_RESERVE if release else 0
                    if release and index < 2:
                        reserve += SIGNING_READ_RESERVE
                    build_timeout = remaining_budget(deadline) - CLEANUP_RESERVE_SECONDS - reserve
                    if build_timeout <= 0:
                        raise RuntimeError("构建预算不足，保留独立 Gradle 清理时间")
                    if release and index == 2:
                        if build_timeout <= SIGNING_READ_RESERVE:
                            raise RuntimeError("正式签名读取与验签预算不足")
                        signing_env = None
                        try:
                            signing_env = release_signing.signing_environment(command.env)
                            build_timeout = remaining_budget(deadline) - CLEANUP_RESERVE_SECONDS - SIGNATURE_VERIFY_RESERVE
                            if build_timeout <= 0:
                                raise RuntimeError("正式 APK 构建预算不足")
                            run(command.argv, command.cwd, signing_env, timeout=build_timeout,
                                network_lease=network_lease, sensitive_output=True)
                        finally:
                            if signing_env is not None:
                                for key in SIGNING_KEYS:
                                    signing_env.pop(key, None)
                    else:
                        run(command.argv, command.cwd, command.env, timeout=build_timeout, network_lease=network_lease)
                    if changed_locks(root, before):
                        raise RuntimeError("依赖锁定文件发生变化，停止后续步骤")
                    if source_snapshot(root, env, deadline) != source_before:
                        raise RuntimeError("源码输入发生变化，停止后续步骤")
                    if index == 0:
                        verify_elf((stage / "libclash.so").read_bytes(), "libclash.so")
                        header = stage / "libclash.h"
                        if not header.is_file() or not header.stat().st_size:
                            raise RuntimeError("核心生成头文件缺失或为空")
                        destination = root / CORE_OUTPUT
                        destination.mkdir(parents=True, exist_ok=True)
                        for name in ("libclash.so", "libclash.h"):
                            os.replace(stage / name, destination / name)
                libraries = verify_apk(root / apk_output)
                if libraries[f"lib/{ABI}/libclash.so"] != sha256(root / CORE_OUTPUT / "libclash.so"):
                    raise RuntimeError("APK 内核心与已生成核心的 SHA256 不一致")
                apk_digest = sha256(root / apk_output)
                if release:
                    if remaining_budget(deadline) <= SIGNATURE_VERIFY_RESERVE + CLEANUP_RESERVE_SECONDS:
                        raise RuntimeError("正式 APK 验签与清理预算不足")
                    signature = release_signing.verify_signed_apk(root / apk_output, env)
                    if signature != {"verified": True, "certificate_sha256": release_signing.CERTIFICATE_SHA256, "signers": 1}:
                        raise RuntimeError("正式 APK 验签证据拒绝")
                    if sha256(root / apk_output) != apk_digest:
                        raise RuntimeError("正式 APK 在验签期间变化")
                    receipt.update(signature_verified=True, certificate_sha256=signature["certificate_sha256"])
                    check_inputs()
                receipt.update({"status": "passed", "artifacts": {
                    str(CORE_OUTPUT / name): sha256(root / CORE_OUTPUT / name)
                    for name in ("libclash.so", "libclash.h")},
                    "apk": {"path": apk_output.as_posix(), "sha256": apk_digest},
                    "apk_libraries": libraries})
    except subprocess.TimeoutExpired:
        receipt["failure_reason"] = "子进程执行超时"
    except Exception as error:
        receipt["failure_reason"] = str(error) if isinstance(error, RuntimeError) else f"执行失败：{type(error).__name__}"
        if isinstance(error, CommandFailed):
            receipt["safe_failure_summary"] = error.summary
    finally:
        if network_lease is not None:
            try:
                network_lease.check()
            except Exception:
                final_failure("最终任务 DNS 租约复核失败")
        try:
            network_stopped = network_lease is None or network_lease.close()
        except Exception:
            network_stopped = False
        receipt["dependency_network"] = {"renewal_stopped": network_stopped,
            "connections": network_lease.history if network_lease is not None else [],
            "transport": "task-loopback-https-connect",
            "hosts": list(dependency_network.HOSTS), "resolver": dependency_network.DOH_ENDPOINT}
        if not network_stopped:
            final_failure("任务 DNS 刷新线程退出证据不足")
        if gradle_started and owned_home is not None:
            try:
                java_identity = JavaIdentity(Path(versions["JavaExecutablePath"]),
                    versions["JavaExecutableSHA256"]) if all(key in versions for key in
                    ("JavaExecutablePath", "JavaExecutableSHA256")) else None
                cleanup = cleanup_gradle(root, owned_home, env, deadline, java_identity=java_identity)
            except Exception:
                cleanup = {"verified": False, "failure_reason": "独立 Gradle 清理无法完成"}
        else:
            cleanup = {"verified": True, "method": "未启动 Gradle 构建", "terminated_pids": []}
        receipt["gradle_cleanup"] = cleanup
        if cleanup.get("verified") is not True:
            final_failure("独立 Gradle daemon/worker 终止证据不足")
        try:
            changed = changed_locks(root, before)
            receipt.update({"locks_unchanged": not changed, "changed_locks": changed})
            if changed:
                final_failure("最终依赖锁定文件检查发现漂移")
        except Exception:
            receipt["locks_unchanged"] = False
            final_failure("最终依赖锁定文件检查无法完成")
        receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
        try:
            source_after = source_snapshot(root, env, deadline)
            receipt["source_after"] = source_after
            receipt["source_unchanged"] = source_after == receipt.get("source_before")
        except Exception:
            receipt["source_unchanged"] = False
        if not receipt["source_unchanged"]:
            final_failure("最终源码输入检查发现漂移或无法完成复核")
        if release and receipt.get("apk"):
            try:
                if sha256(root / apk_output) != receipt["apk"]["sha256"]:
                    raise RuntimeError("正式 APK 最终摘要变化")
            except Exception:
                receipt["signature_verified"] = False
                final_failure("正式 APK 最终摘要变化或无法复核")
        receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    if receipt["status"] != "passed":
        raise RuntimeError(str(receipt.get("failure_reason", "Android 构建失败")))
    return receipt_path


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="执行核心与 debug APK 构建，不安装或发行")
    parser.add_argument("--release", action="store_true", help="显式构建正式签名 APK；不安装、上传或发布")
    parser.add_argument("--network-check-only", action="store_true", help="执行时仅通过官方网络与 Gradle help 门禁，不构建 APK")
    parser.add_argument("--sdk", type=Path, help="Android SDK 根目录")
    parser.add_argument("--framework-validator", type=Path,
                        help="已安装统一 PDEC 验证器路径，也可通过 BETTBOX_PDEC_VALIDATOR 指定")
    args = parser.parse_args(argv)
    if args.release and args.network_check_only:
        parser.error("--release 不能与 --network-check-only 组合")
    deadline = time.monotonic() + BUILD_BUDGET_SECONDS if args.execute else None
    root = Path(__file__).resolve().parents[1]
    sdk = (args.sdk or Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
                           or str(Path.home() / "Library/Android/sdk"))).expanduser().resolve()
    before = snapshot_locks(root)
    try:
        if args.execute:
            versions, env = preflight(root, sdk, deadline)
        else:
            # 计划模式不调用 Flutter doctor 或任何可能联网、写缓存的工具。
            versions = {"Flutter": FLUTTER_VERSION, "Go": GO_VERSION, "NDK": NDK_VERSION, "CMake": CMAKE_VERSION}
            env = build_environment({"BETTBOX_FLUTTER": "flutter", "BETTBOX_GO": "go",
                "BETTBOX_CC": str(sdk / "ndk" / NDK_VERSION / "toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang"),
                "BETTBOX_ZIPALIGN": str(sdk / "build-tools/36.0.0/zipalign")})
    except Exception as error:
        if args.execute:
            receipt_path = root / ".test/android-build/receipt.json"
            receipt_path.parent.mkdir(parents=True, exist_ok=True)
            changed = changed_locks(root, before)
            receipt_path.write_text(json.dumps({
                "target": "android-arm64-release" if args.release else "android-arm64-debug", "status": "failed", "phase": "preflight",
                "failure_reason": str(error) if isinstance(error, RuntimeError) else f"预检失败：{type(error).__name__}",
                "locks_before": before, "locks_unchanged": not changed, "changed_locks": changed,
                "release_verified": False, "source_unchanged": False,
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }, ensure_ascii=False, indent=2) + "\n")
        raise
    if changed_locks(root, before):
        raise RuntimeError("预检期间依赖锁定文件发生变化")
    print(("工具链已核验：" if args.execute else "工具链要求：") + json.dumps(versions, ensure_ascii=False))
    print("目标：Android arm64 " + ("release" if args.release else "debug") + "；模式：" + ("执行" if args.execute else "只展示计划"))
    print("官方依赖网络计划：" + json.dumps(dependency_network.plan(), ensure_ascii=False))
    print("顺序：Java TLS → Gradle help" + ("" if args.network_check_only else
          " → Go 只读依赖 arm64 核心 → 锁定 pub get → " + ("正式签名 APK → 验签" if args.release else "debug APK") + " → 16KiB 产物核验"))
    print("依赖锁定文件 SHA256：" + json.dumps(before, ensure_ascii=False))
    if args.execute:
        configured = args.framework_validator or os.environ.get("BETTBOX_PDEC_VALIDATOR")
        validator = Path(configured).expanduser().resolve() if configured else None
        print(f"回执：{execute(root, versions, env, validator, deadline=deadline, network_check_only=args.network_check_only, release=args.release).relative_to(root)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"Android 开发构建失败：{error}")
        raise SystemExit(1)
