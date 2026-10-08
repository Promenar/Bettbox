#!/usr/bin/env python3
"""Bettbox 桌面原生编译验证入口。

默认只执行前置检查并打印将运行的真实命令；显式传入 ``--execute`` 才会
编译。该入口只产出开发验证产物，不打包、不执行发布动作。
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence


CORE_IDENTIFIER = "com.appshub.bettbox.core"
CORE_IDENTITY_PATH = Path("libclash/macos/BettboxCoreIdentity.json")

FLUTTER_VERSION = "3.44.9"
RUST_VERSION = "1.98.0"
SENSITIVE_ENV_NAME = re.compile(
    r"(?:TOKEN|SECRET|PASSWORD|PASSWD|COOKIE|CREDENTIAL|PRIVATE_KEY|API_KEY|AUTH|DSN)",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Target:
    name: str
    system: str
    machine: str
    goos: str
    goarch: str
    go_version_prefix: str
    core_path: Path
    bundle_path: Path
    bundled_core_path: Path
    bundled_helper_path: Path | None
    app_paths: tuple[Path, ...]
    needs_helper: bool


TARGETS = {
    "macos-arm64": Target(
        name="macos-arm64",
        system="Darwin",
        machine="arm64",
        goos="darwin",
        goarch="arm64",
        go_version_prefix="1.26.",
        core_path=Path("libclash/macos/BettboxCore"),
        bundle_path=Path("build/macos/Build/Products/Release/Bettbox.app"),
        bundled_core_path=Path(
            "build/macos/Build/Products/Release/Bettbox.app/Contents/MacOS/BettboxCore"
        ),
        bundled_helper_path=None,
        app_paths=(
            Path("build/macos/Build/Products/Release/Bettbox.app/Contents/MacOS/Bettbox"),
            Path("build/macos/Build/Products/Release/Bettbox.app/Contents/Frameworks/App.framework/App"),
        ),
        needs_helper=False,
    ),
    "windows-x64": Target(
        name="windows-x64",
        system="Windows",
        machine="x86_64",
        goos="windows",
        goarch="amd64",
        go_version_prefix="1.25.",
        core_path=Path("libclash/windows/BettboxCore.exe"),
        bundle_path=Path("build/windows/x64/runner/Release"),
        bundled_core_path=Path(
            "build/windows/x64/runner/Release/BettboxCore.exe"
        ),
        bundled_helper_path=Path(
            "build/windows/x64/runner/Release/BettboxHelperService.exe"
        ),
        app_paths=(
            Path("build/windows/x64/runner/Release/Bettbox.exe"),
            Path("build/windows/x64/runner/Release/BettboxCore.exe"),
            Path("build/windows/x64/runner/Release/BettboxHelperService.exe"),
        ),
        needs_helper=True,
    ),
}

LOCK_FILES = (
    Path("pubspec.lock"),
    Path("core/go.sum"),
    Path("services/helper/Cargo.lock"),
    Path("macos/Podfile.lock"),
    Path("macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
)

SOURCE_SCOPE = (
    "lib", "core", "macos", "windows", "services/helper", "plugins",
    "assets", "arb", "scripts", "pubspec.yaml", "pubspec.lock",
)


def checked_source_parents(root: Path, path: Path) -> dict[str, tuple[int, ...]]:
    """Windows 回退核对 reparse point；这不等同 POSIX 目录句柄隔离。"""
    snapshot = {}
    for parent in (path, *path.parents):
        if parent == root:
            break
        info = parent.lstat()
        attributes = getattr(info, "st_file_attributes", 0)
        if stat.S_ISLNK(info.st_mode) or attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise RuntimeError("源码输入包含链接或 reparse point")
        snapshot[str(parent)] = (info.st_dev, info.st_ino, info.st_mode, attributes)
    return snapshot


def source_file_hash(root: Path, name: str) -> str | None:
    """冻结构建输入字节；拒绝链接及读取期间变化，不读取签名配置。"""
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("源码输入路径越界")
    if relative.name.startswith(".env") or relative.name == "local.properties" or \
            relative.suffix.lower() in (".jks", ".keystore", ".pem", ".key", ".p12", ".pfx"):
        return None
    # 支持 dir_fd 的平台逐层打开目录，避免父目录链接替换使读取越界。
    parent_snapshot = None
    if os.open in os.supports_dir_fd:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in relative.parts[:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                os.close(directory)
                directory = child
            descriptor = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        finally:
            os.close(directory)
    else:
        path = root / relative
        parent_snapshot = checked_source_parents(root, path)
        descriptor = os.open(path, os.O_RDONLY)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError("源码输入不是普通文件")
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_mode)
        if identity(before) != identity(after) or identity(after) != identity((root / relative).lstat()):
            raise RuntimeError("源码输入在冻结期间发生变化")
        if parent_snapshot is not None and parent_snapshot != checked_source_parents(root, root / relative):
            raise RuntimeError("源码父路径在冻结期间发生变化")
    return digest.hexdigest()


@dataclass(frozen=True)
class Command:
    argv: tuple[str, ...]
    cwd: Path
    env: Mapping[str, str] | None = None
    label: str = ""
    capture_output: bool = False
    check: bool = True
    stage: str = ""


def repository_root() -> Path:
    # Windows CI 通过临时盘符缩短 checkout 路径；不要把映射解析回长路径。
    return Path(os.path.abspath(__file__)).parents[1]


def normalized_machine(machine: str) -> str:
    value = machine.lower()
    if value in {"arm64", "aarch64"}:
        return "arm64"
    if value in {"amd64", "x86_64", "x64"}:
        return "x86_64"
    return value


def validate_host(target: Target, system: str, machine: str) -> None:
    actual_machine = normalized_machine(machine)
    if system != target.system or actual_machine != target.machine:
        raise RuntimeError(
            f"目标 {target.name} 必须在 {target.system}/{target.machine} 原生执行，"
            f"当前为 {system}/{actual_machine}"
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_locks(root: Path) -> dict[Path, str]:
    missing = [path for path in LOCK_FILES if not (root / path).is_file()]
    if missing:
        names = ", ".join(path.as_posix() for path in missing)
        raise RuntimeError(f"缺少依赖锁文件：{names}")
    return {path: sha256_file(root / path) for path in LOCK_FILES}


def assert_locks_unchanged(root: Path, before: Mapping[Path, str]) -> None:
    changed = [
        path
        for path, digest in before.items()
        if not (root / path).is_file() or sha256_file(root / path) != digest
    ]
    if changed:
        names = ", ".join(path.as_posix() for path in changed)
        raise RuntimeError(f"构建期间依赖锁文件发生变化：{names}")


def evaluate_locks(
    root: Path, before: Mapping[Path, str]
) -> tuple[bool, dict[str, str | None], list[str]]:
    current: dict[str, str | None] = {}
    changed: list[str] = []
    for path, digest in before.items():
        file_path = root / path
        current_digest = sha256_file(file_path) if file_path.is_file() else None
        current[path.as_posix()] = current_digest
        if current_digest != digest:
            changed.append(path.as_posix())
    return not changed, current, changed


def _version_output(argv: Sequence[str], root: Path) -> str:
    result = subprocess.run(
        executable_argv(argv),
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=sanitized_environment(),
    )
    return result.stdout.strip()


def executable_argv(argv: Sequence[str]) -> tuple[str, ...]:
    # Windows CreateProcess 不按 PATHEXT 查找无后缀的 flutter/dart 批处理入口。
    return (shutil.which(argv[0]) or argv[0], *argv[1:])


def parse_flutter_version(output: str) -> str:
    # Windows SDK 首次启动会先运行工具初始化，日志可能位于版本 JSON 前。
    decoder = json.JSONDecoder()
    candidates: list[tuple[str, int]] = []
    for match in re.finditer(r"\{", output):
        try:
            value, _ = decoder.raw_decode(output, match.start())
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        version = value.get("frameworkVersion")
        if (
            isinstance(version, str)
            and re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][\w.+-]+)?", version)
            and isinstance(value.get("dartSdkVersion"), str)
        ):
            candidates.append((version, match.start()))
    if len(candidates) != 1:
        raise RuntimeError("无法解析唯一的 Flutter 版本 JSON")
    version, start = candidates[0]
    if output[:start].strip():
        print(f"Flutter 版本 JSON 前含 {len(output[:start].splitlines())} 行初始化输出，已独立解析。")
    return version


def check_tool_versions(root: Path, target: Target) -> dict[str, str]:
    required = ["flutter", "dart", "go"]
    if target.needs_helper:
        required.extend(["cargo", "rustc", "cmake"])
    else:
        required.extend(["xcodebuild", "pod", "codesign"])
    missing = [name for name in required if shutil.which(name) is None]
    if missing:
        raise RuntimeError(f"缺少构建工具：{', '.join(missing)}")

    flutter_raw = _version_output(("flutter", "--version", "--machine"), root)
    flutter_version = parse_flutter_version(flutter_raw)
    go_raw = _version_output(("go", "version"), root)
    go_match = re.search(r"\bgo(\d+\.\d+(?:\.\d+)?)\b", go_raw)
    if go_match is None:
        raise RuntimeError("无法解析 Go 版本")
    go_version = go_match.group(1)

    dart_raw = _version_output(("dart", "--version"), root)
    versions = {
        "Flutter": flutter_version,
        "Dart": dart_raw.splitlines()[0],
        "Go": go_version,
    }
    if flutter_version != FLUTTER_VERSION:
        raise RuntimeError(
            f"Flutter 版本不匹配：需要 {FLUTTER_VERSION}，实际 {flutter_version}"
        )
    if not go_version.startswith(target.go_version_prefix):
        raise RuntimeError(
            f"Go 版本不匹配：需要 {target.go_version_prefix}x，实际 {go_version}"
        )

    if target.needs_helper:
        rust_raw = _version_output(("rustc", "--version"), root)
        rust_match = re.search(r"\brustc\s+(\d+\.\d+\.\d+)\b", rust_raw)
        if rust_match is None:
            raise RuntimeError("无法解析 Rust 版本")
        rust_version = rust_match.group(1)
        if rust_version != RUST_VERSION:
            raise RuntimeError(
                f"Rust 版本不匹配：需要 {RUST_VERSION}，实际 {rust_version}"
            )
        versions["Rust"] = rust_version
        cargo_raw = _version_output(("cargo", "--version"), root)
        cmake_raw = _version_output(("cmake", "--version"), root)
        versions["Cargo"] = cargo_raw.splitlines()[0]
        versions["CMake"] = cmake_raw.splitlines()[0]
    else:
        xcode_raw = _version_output(("xcodebuild", "-version"), root)
        pod_raw = _version_output(("pod", "--version"), root)
        versions["Xcode"] = " / ".join(xcode_raw.splitlines())
        versions["CocoaPods"] = pod_raw.splitlines()[0]
    return versions


def sanitized_environment(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if SENSITIVE_ENV_NAME.search(key) is None
    }
    if extra:
        environment.update(extra)
    return environment


def signing_mode(target: Target, unsigned_macos: bool) -> str:
    if unsigned_macos and target.needs_helper:
        raise RuntimeError("--unsigned-macos 仅支持 macos-arm64 目标")
    return "unsigned" if unsigned_macos else ("not-applicable" if target.needs_helper else "adhoc-verified")


def command_plan(
    root: Path,
    target: Target,
    core_sha256: str,
    unsigned_macos: bool = False,
    local_development_keychain: bool = False,
) -> list[Command]:
    signing_mode(target, unsigned_macos)
    if local_development_keychain and (target.needs_helper or not unsigned_macos):
        raise RuntimeError("本机开发Keychain仅支持显式unsigned macOS构建")
    core_env = {
        "GOOS": target.goos,
        "GOARCH": target.goarch,
        "CGO_ENABLED": "0",
    }
    if target.goarch == "amd64":
        core_env["GOAMD64"] = "v1"

    commands = [
        Command(
            ("flutter", "pub", "get", "--enforce-lockfile"),
            root,
            label="恢复 Flutter 锁定依赖",
            stage="prepare",
        ),
        Command(
            (
                "go",
                "build",
                "-mod=readonly",
                "-trimpath",
                "-ldflags=-w -s",
                "-tags=with_gvisor",
                "-o",
                str(Path("..") / target.core_path),
                ".",
            ),
            root / "core",
            env=core_env,
            label="编译 Mihomo core",
            stage="prepare",
        ),
    ]

    if not target.needs_helper:
        labels = ("最终 ad hoc 签名 macOS core", "验证 macOS core 签名", "读取 macOS core 公开身份")
        commands.extend(Command(argv, root, label=label, capture_output=argv[1] == "--display", stage="core-sign")
                        for argv, label in zip(core_identity_module.core_signing_arguments(), labels))

    if target.needs_helper:
        commands.append(
            Command(
                ("cargo", "build", "--release", "--locked", "--features", "windows-service"),
                root / "services/helper",
                env={"TOKEN": core_sha256},
                label="编译 Windows helper",
                stage="dependencies",
            )
        )
    else:
        commands.append(Command(
            (sys.executable, "scripts/macos_supervisor_artifact.py", "--prepare"),
            root, label="编译并签名固定 macOS supervisor", stage="dependencies",
        ))
        commands.append(
            Command(
                ("pod", "install", "--deployment"),
                root / "macos",
                label="恢复 macOS 锁定 Pod 依赖",
                stage="dependencies",
            )
        )

    flutter_args = (
        "flutter",
        "build",
        "windows" if target.needs_helper else "macos",
        "--release",
        f"--dart-define=CORE_SHA256={core_sha256}",
        "--dart-define=APP_ENV=local-macos-development" if local_development_keychain else "--dart-define=APP_ENV=pre",
    )
    if local_development_keychain:
        flutter_args += ("--dart-define=BETTBOX_MACOS_DEVELOPMENT_KEYCHAIN=true",)
    commands.append(
        Command(
            flutter_args,
            root,
            env={"FLUTTER_XCODE_CODE_SIGNING_ALLOWED": "NO"}
            if unsigned_macos
            else None,
            label="编译 Flutter 桌面应用",
            stage="flutter",
        )
    )
    if not target.needs_helper and not unsigned_macos:
        bundle = target.bundle_path.as_posix()
        commands.extend(
            [
                Command(
                    ("codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle),
                    root,
                    label="验证 macOS bundle 签名",
                    stage="bundle-signature",
                ),
                Command(
                    ("codesign", "--display", "--verbose=4", bundle),
                    root,
                    label="读取 macOS bundle 签名证据",
                    stage="bundle-signature",
                    capture_output=True,
                ),
            ]
        )
    elif unsigned_macos:
        commands.append(
            Command(
                ("codesign", "--display", "--verbose=4", target.bundle_path.as_posix()),
                root,
                label="读取 macOS 编译产物签名事实",
                    stage="bundle-signature",
                capture_output=True,
                check=False,
            )
        )
    return commands


def display_command(command: Command, root: Path) -> str:
    try:
        relative_cwd = command.cwd.relative_to(root).as_posix() or "."
    except ValueError:
        relative_cwd = command.cwd.as_posix()
    env = ""
    if command.env:
        visible = []
        for key, value in command.env.items():
            shown = "<core-sha256>" if key == "TOKEN" else value
            visible.append(f"{key}={shown}")
        env = " ".join(visible) + " "
    argv = " ".join(_shell_quote(part) for part in command.argv)
    return f"[{relative_cwd}] {env}{argv}"


def _shell_quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:=+-]+", value):
        return value
    return repr(value)


def run_commands(commands: Sequence[Command]) -> list[str | None]:
    outputs: list[str | None] = []
    for command in commands:
        environment = sanitized_environment(command.env)
        print(f"执行：{command.label}", flush=True)
        result = subprocess.run(
            executable_argv(command.argv),
            cwd=command.cwd,
            env=environment,
            check=command.check,
            text=command.capture_output,
            stdout=subprocess.PIPE if command.capture_output else None,
            stderr=subprocess.STDOUT if command.capture_output else None,
        )
        outputs.append(result.stdout.strip() if command.capture_output else None)
    return outputs


def copy_windows_helper(root: Path) -> Path:
    source = root / "services/helper/target/release/helper.exe"
    destination = root / "libclash/windows/BettboxHelperService.exe"
    if not source.is_file():
        raise RuntimeError(f"Windows helper 产物不存在：{source.relative_to(root)}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return destination


def _artifact_evidence(root: Path, path: Path) -> dict[str, object]:
    return {
        "path": path.relative_to(root).as_posix(),
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def git_source_state(root: Path) -> dict[str, object]:
    environment = sanitized_environment()
    head = subprocess.run(
        ("git", "rev-parse", "HEAD"),
        cwd=root,
        env=environment,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout.strip()
    status_output = subprocess.run(
        ("git", "status", "--porcelain=v1", "--untracked-files=all"),
        cwd=root,
        env=environment,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout
    diff = subprocess.run(
        ("git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"),
        cwd=root,
        env=environment,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout
    status = [line for line in status_output.splitlines() if line]
    listed = subprocess.run(
        ("git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", *SOURCE_SCOPE),
        cwd=root, env=environment, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout.decode("utf-8").split("\0")
    hashes = {}
    for name in sorted(set(filter(None, listed))):
        path = root / name
        if not path.exists() and not path.is_symlink():
            hashes[name] = None
        elif path.is_symlink():
            raise RuntimeError("源码输入包含符号链接")
        elif path.is_dir():
            # gitlink 的工作树必须独立展开，不能只记录目录名。
            nested = subprocess.run(
                ("git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"),
                cwd=path, env=environment, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            ).stdout.decode("utf-8").split("\0")
            for item in sorted(set(filter(None, nested))):
                relative = f"{name}/{item}"
                nested_path = root / relative
                hashes[relative] = (source_file_hash(root, relative)
                                    if nested_path.exists() or nested_path.is_symlink() else None)
        else:
            hashes[name] = source_file_hash(root, name)
    return {
        "head": head,
        "dirty": bool(status),
        "status": status,
        "tracked_diff_sha256": hashlib.sha256(diff).hexdigest(),
        "source_sha256": hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
        "source_file_count": len(hashes),
    }


def source_state_unchanged(
    before: Mapping[str, object], after: Mapping[str, object]
) -> bool:
    return before == after


def parse_adhoc_signature(output: str) -> list[str]:
    evidence = [
        line.strip()
        for line in output.splitlines()
        if line.strip().startswith(("Signature=", "TeamIdentifier=", "Authority="))
    ]
    if "Signature=adhoc" not in evidence or "TeamIdentifier=not set" not in evidence:
        raise RuntimeError("macOS bundle 不是无 Team 的 ad hoc 签名")
    return evidence


def parse_unsigned_signature(output: str) -> list[str]:
    prefixes = ("Signature=", "TeamIdentifier=", "Sealed Resources=", "Info.plist=")
    return [
        line.strip()
        for line in output.splitlines()
        if line.strip().startswith(prefixes)
    ]


def commands_in_stage(plan: Sequence[Command], stage: str) -> list[Command]:
    return [command for command in plan if command.stage == stage]


# 共享模块也供 setup.dart 的独立 CLI 使用；路径来自脚本自身，不依赖 cwd/import 搜索顺序。
_identity_spec = importlib.util.spec_from_file_location("bettbox_macos_core_identity", Path(__file__).with_name("macos_core_identity.py"))
assert _identity_spec is not None and _identity_spec.loader is not None
core_identity_module = importlib.util.module_from_spec(_identity_spec)
_identity_spec.loader.exec_module(core_identity_module)
sys.modules.setdefault("macos_core_identity", core_identity_module)
_supervisor_spec = importlib.util.spec_from_file_location("bettbox_macos_supervisor_artifact", Path(__file__).with_name("macos_supervisor_artifact.py"))
assert _supervisor_spec is not None and _supervisor_spec.loader is not None
supervisor_artifact_module = importlib.util.module_from_spec(_supervisor_spec)
_supervisor_spec.loader.exec_module(supervisor_artifact_module)
parse_core_signature = core_identity_module.parse_core_signature
validate_core_identity = core_identity_module.validate_core_identity
read_core_identity = core_identity_module.read_core_identity


def finalize_core_identity(root: Path, target: Target, plan: Sequence[Command]) -> dict[str, object]:
    if target.core_path != core_identity_module.CORE_EXECUTABLE:
        raise RuntimeError("macOS core 路径不符合共享签名合同")
    return core_identity_module.prepare_core_identity(root)


def validate_bundle(
    root: Path, target: Target, expected_core_identity: Mapping[str, object] | None = None
) -> tuple[list[dict[str, object]], list[dict[str, object]], list[dict[str, object]]]:
    source_paths = [root / target.core_path]
    if target.needs_helper:
        source_paths.append(root / "libclash/windows/BettboxHelperService.exe")
    else:
        source_paths.append(root / supervisor_artifact_module.EXECUTABLE)
    required = [
        *source_paths,
        *(root / path for path in target.app_paths),
        root / target.bundled_core_path,
    ]
    if target.bundled_helper_path is not None:
        required.append(root / target.bundled_helper_path)
    missing = [path for path in required if not path.is_file()]
    if missing:
        names = ", ".join(path.relative_to(root).as_posix() for path in missing)
        raise RuntimeError(f"缺少预期构建产物：{names}")

    bindings = [
        {
            "source": target.core_path.as_posix(),
            "bundled": target.bundled_core_path.as_posix(),
            "sha256": sha256_file(root / target.core_path),
        }
    ]
    if sha256_file(root / target.core_path) != sha256_file(root / target.bundled_core_path):
        raise RuntimeError("bundle 内 core 与本次编译的 core SHA256 不一致")

    if not target.needs_helper:
        helper_identity, helper_bytes = supervisor_artifact_module.read_identity(root)
        helper_bundle = target.bundle_path / "Contents/MacOS/BettboxCoreSupervisor"
        bundled_identity = root / target.bundle_path / "Contents/Resources/BettboxCoreSupervisorIdentity.json"
        if helper_bytes != bundled_identity.read_bytes() or helper_identity["sha256"] != sha256_file(root / helper_bundle) or \
                sha256_file(root / supervisor_artifact_module.EXECUTABLE) != helper_identity["sha256"]:
            raise RuntimeError("supervisor封装字节或清单不符")
        outputs = supervisor_artifact_module.run_commands(root, [
            ("/usr/bin/codesign", "--verify", "--strict", helper_bundle.as_posix()),
            ("/usr/bin/codesign", "--display", "--verbose=4", helper_bundle.as_posix()),
        ])
        actual_helper = supervisor_artifact_module.parse_signature(outputs[-1] or "")
        actual_helper["sha256"] = sha256_file(root / helper_bundle)
        if actual_helper != helper_identity: raise RuntimeError("supervisor实际签名不符")
        bindings.append({"source": supervisor_artifact_module.EXECUTABLE.as_posix(),
                         "bundled": helper_bundle.as_posix(), "sha256": helper_identity["sha256"],
                         "identity": helper_identity})
        identity, source_bytes = read_core_identity(root, CORE_IDENTITY_PATH)
        bundled_manifest = target.bundle_path / "Contents/Resources/BettboxCoreIdentity.json"
        bundled_identity, bundled_bytes = read_core_identity(root, bundled_manifest)
        if identity != bundled_identity or source_bytes != bundled_bytes or \
                (expected_core_identity is not None and dict(expected_core_identity) != identity) or \
                identity["sha256"] != bindings[0]["sha256"]:
            raise RuntimeError("core 身份 manifest 与冻结产物不一致")
        outputs = core_identity_module.run_identity_commands(root, [
            ("codesign", "--verify", "--strict", target.bundled_core_path.as_posix()),
            ("codesign", "--display", "--verbose=4", target.bundled_core_path.as_posix()),
        ])
        actual = parse_core_signature(outputs[-1] or "")
        actual["sha256"] = sha256_file(root / target.bundled_core_path)
        if actual != identity or sha256_file(root / target.core_path) != identity["sha256"]:
            raise RuntimeError("打包后 core 身份或字节发生漂移")
        bindings[0]["core_identity"] = identity

    if target.bundled_helper_path is not None:
        helper_source = root / "libclash/windows/BettboxHelperService.exe"
        helper_bundle = root / target.bundled_helper_path
        helper_sha = sha256_file(helper_source)
        if helper_sha != sha256_file(helper_bundle):
            raise RuntimeError("bundle 内 helper 与本次编译的 helper SHA256 不一致")
        bindings.append(
            {
                "source": helper_source.relative_to(root).as_posix(),
                "bundled": target.bundled_helper_path.as_posix(),
                "sha256": helper_sha,
            }
        )

    bundle_root = root / target.bundle_path
    if not bundle_root.is_dir():
        raise RuntimeError(f"bundle 目录不存在：{target.bundle_path.as_posix()}")
    bundle_files = [
        _artifact_evidence(root, path)
        for path in sorted(bundle_root.rglob("*"), key=lambda item: item.as_posix())
        if path.is_file()
    ]
    if not bundle_files:
        raise RuntimeError("bundle 目录中没有可校验文件")
    sources = [_artifact_evidence(root, path) for path in source_paths]
    return sources, bundle_files, bindings


def write_manifest(root: Path, target: Target, manifest: Mapping[str, object]) -> Path:
    destination = root / "build/desktop-validation" / f"{target.name}.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(destination)
    return destination


def close_failed_execution(
    root: Path,
    target: Target,
    started_at: str,
    lock_snapshot: Mapping[Path, str],
    source_before: Mapping[str, object],
    error: BaseException,
    requested_signing_mode: str,
    commands_succeeded: bool,
) -> None:
    closure_problems: list[str] = []
    try:
        source_after: Mapping[str, object] = git_source_state(root)
        source_unchanged: bool | None = source_state_unchanged(
            source_before, source_after
        )
    except Exception as closure_error:  # 失败收口不得覆盖原始命令异常。
        source_after = {"collection_error": str(closure_error)}
        source_unchanged = None
        closure_problems.append(f"源码状态采集失败：{closure_error}")

    try:
        locks_unchanged, lock_current, changed_locks = evaluate_locks(
            root, lock_snapshot
        )
    except Exception as closure_error:  # 失败收口不得覆盖原始命令异常。
        locks_unchanged = None
        lock_current = {}
        changed_locks = []
        closure_problems.append(f"锁文件状态采集失败：{closure_error}")

    command_error: dict[str, object] = {
        "type": type(error).__name__,
        "message": str(error),
    }
    if isinstance(error, subprocess.CalledProcessError):
        command_error["returncode"] = error.returncode
        command_error["command"] = list(error.cmd) if not isinstance(error.cmd, str) else error.cmd

    manifest = {
        "schema_version": 1,
        "target": target.name,
        "started_at": started_at,
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "commands_succeeded": commands_succeeded,
        "requested_signing_mode": requested_signing_mode,
        "command_error": command_error,
        "source_unchanged": source_unchanged,
        "locks_unchanged": locks_unchanged,
        "source_before": source_before,
        "source_after": source_after,
        "lock_sha256_before": {
            path.as_posix(): digest for path, digest in sorted(lock_snapshot.items())
        },
        "lock_sha256_after": lock_current,
        "changed_locks": changed_locks,
        "closure_problems": closure_problems,
    }
    manifest_path: Path | None = None
    try:
        manifest_path = write_manifest(root, target, manifest)
    except Exception as closure_error:  # 失败收口不得覆盖原始命令异常。
        closure_problems.append(f"失败 manifest 写入失败：{closure_error}")

    summary_parts = [
        f"source_unchanged={source_unchanged}",
        f"locks_unchanged={locks_unchanged}",
    ]
    if changed_locks:
        summary_parts.append(f"changed_locks={','.join(changed_locks)}")
    if manifest_path is not None:
        summary_parts.append(
            f"manifest={manifest_path.relative_to(root).as_posix()}"
        )
    summary_parts.extend(closure_problems)
    error.add_note("失败收口｜" + "；".join(summary_parts))


def execute_build(
    root: Path, target: Target, unsigned_macos: bool = False,
    local_development_keychain: bool = False,
) -> None:
    started_at = datetime.now(timezone.utc).isoformat()
    requested_signing_mode = signing_mode(target, unsigned_macos)
    lock_snapshot = snapshot_locks(root)
    source_before = git_source_state(root)
    core_path = root / target.core_path
    placeholder = "<core-sha256>"
    initial_plan = command_plan(root, target, placeholder, unsigned_macos=unsigned_macos,
                                local_development_keychain=local_development_keychain)
    initial_commands = commands_in_stage(initial_plan, "prepare")
    core_identity = None
    signature_output = ""
    commands_succeeded = False
    try:
        run_commands(initial_commands)
        if not core_path.is_file():
            raise RuntimeError(f"core 产物不存在：{target.core_path.as_posix()}")
        if not target.needs_helper:
            core_identity = finalize_core_identity(root, target, initial_plan)
        core_sha256 = core_identity["sha256"] if core_identity is not None else sha256_file(core_path)
        plan = command_plan(
            root, target, core_sha256, unsigned_macos=unsigned_macos,
            local_development_keychain=local_development_keychain
        )
        run_commands(commands_in_stage(plan, "dependencies"))
        if target.needs_helper:
            copy_windows_helper(root)
        run_commands(commands_in_stage(plan, "flutter"))
        if not target.needs_helper:
            signature_outputs = run_commands(commands_in_stage(plan, "bundle-signature"))
            signature_output = signature_outputs[-1] or ""
        commands_succeeded = True

        signature_evidence = (
            []
            if target.needs_helper
            else (
                parse_unsigned_signature(signature_output)
                if unsigned_macos
                else parse_adhoc_signature(signature_output)
            )
        )
        source_after = git_source_state(root)
        locks_unchanged, _, _ = evaluate_locks(root, lock_snapshot)
        sources, bundle_files, bindings = validate_bundle(root, target, core_identity)
        source_unchanged = source_state_unchanged(source_before, source_after)
        manifest = {
            "schema_version": 1,
            "target": target.name,
            "started_at": started_at,
            "completed_at": datetime.now(timezone.utc).isoformat(),
            "commands_succeeded": True,
            "requested_signing_mode": requested_signing_mode,
            "source_unchanged": source_unchanged,
            "locks_unchanged": locks_unchanged,
            "source_before": source_before,
            "source_after": source_after,
            "lock_sha256": {
                path.as_posix(): digest
                for path, digest in sorted(lock_snapshot.items())
            },
            "source_artifacts": sources,
            "bundle_path": target.bundle_path.as_posix(),
            "bundle_files": bundle_files,
            "bundle_bindings": bindings,
            "signature_evidence": signature_evidence,
            "core_identity": core_identity,
            "host_signing_mode": requested_signing_mode,
            "build_channel": "local-macos-development" if local_development_keychain else "pre",
            "local_development_keychain": local_development_keychain,
        }
        manifest_path = write_manifest(root, target, manifest)
        print(f"验证清单：{manifest_path.relative_to(root).as_posix()}")
        for artifact in sources:
            print(f"  {artifact['sha256']}  {artifact['path']}")
        if not locks_unchanged:
            raise RuntimeError("构建期间依赖锁文件发生变化，验证清单已记录")
        if not source_unchanged:
            raise RuntimeError("构建期间候选源码状态发生变化，验证清单已记录")
    except Exception as error:
        close_failed_execution(
            root,
            target,
            started_at,
            lock_snapshot,
            source_before,
            error,
            requested_signing_mode,
            commands_succeeded,
        )
        raise


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(TARGETS), required=True)
    parser.add_argument(
        "--execute",
        action="store_true",
        help="通过前置检查后执行不打包、不发布的原生编译",
    )
    parser.add_argument(
        "--unsigned-macos",
        action="store_true",
        help="关闭 Xcode signing 编译 macOS 候选；不作为登录、权限或持久化验收",
    )
    parser.add_argument("--local-development-keychain", action="store_true",
                        help="独立macOS本机开发Keychain构建；不能用于正式发行")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8")
    args = parse_args(argv)
    root = repository_root()
    target = TARGETS[args.target]
    signing_mode(target, args.unsigned_macos)
    if not (root / "pubspec.yaml").is_file():
        raise RuntimeError(f"无法识别 Bettbox 仓库根目录：{root}")

    validate_host(target, platform.system(), platform.machine())
    snapshot_locks(root)
    versions = check_tool_versions(root, target)
    mode = "执行" if args.execute else "preflight/dry-run"
    print(f"目标：{target.name}；模式：{mode}")
    print("工具版本：" + "，".join(f"{key} {value}" for key, value in versions.items()))
    print("命令计划：")
    for command in command_plan(
        root,
        target,
        "<core-sha256>",
        unsigned_macos=args.unsigned_macos,
        local_development_keychain=args.local_development_keychain,
    ):
        print(f"  {display_command(command, root)}")

    if args.execute:
        execute_build(root, target, unsigned_macos=args.unsigned_macos,
                      local_development_keychain=args.local_development_keychain)
    else:
        print("preflight 完成；未执行编译。传入 --execute 后才会构建。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"错误：{error}", file=sys.stderr)
        for note in getattr(error, "__notes__", ()):
            print(note, file=sys.stderr)
        raise SystemExit(1) from error
