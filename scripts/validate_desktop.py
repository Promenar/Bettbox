#!/usr/bin/env python3
"""Bettbox 桌面原生编译验证入口。

默认只执行前置检查并打印将运行的真实命令；显式传入 ``--execute`` 才会
编译。该入口只产出开发验证产物，不打包、不执行发布动作。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence


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
            "build/macos/Build/Products/Release/Bettbox.app/Contents/Resources/BettboxCore"
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


@dataclass(frozen=True)
class Command:
    argv: tuple[str, ...]
    cwd: Path
    env: Mapping[str, str] | None = None
    label: str = ""
    capture_output: bool = False


def repository_root() -> Path:
    # Windows CI 通过临时盘符缩短 checkout 路径；不要把映射解析回长路径。
    return Path(__file__).absolute().parents[1]


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


def _version_output(argv: Sequence[str], root: Path) -> str:
    result = subprocess.run(
        argv,
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=sanitized_environment(),
    )
    return result.stdout.strip()


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
    try:
        flutter_version = str(json.loads(flutter_raw)["frameworkVersion"])
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise RuntimeError("无法解析 Flutter 版本") from error
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


def command_plan(root: Path, target: Target, core_sha256: str) -> list[Command]:
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
        ),
    ]

    if target.needs_helper:
        commands.append(
            Command(
                ("cargo", "build", "--release", "--locked", "--features", "windows-service"),
                root / "services/helper",
                env={"TOKEN": core_sha256},
                label="编译 Windows helper",
            )
        )
    else:
        commands.append(
            Command(
                ("pod", "install", "--deployment"),
                root / "macos",
                label="恢复 macOS 锁定 Pod 依赖",
            )
        )

    flutter_args = (
        "flutter",
        "build",
        "windows" if target.needs_helper else "macos",
        "--release",
        f"--dart-define=CORE_SHA256={core_sha256}",
        "--dart-define=APP_ENV=pre",
    )
    commands.append(Command(flutter_args, root, label="编译 Flutter 桌面应用"))
    if not target.needs_helper:
        bundle = target.bundle_path.as_posix()
        commands.extend(
            [
                Command(
                    ("codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle),
                    root,
                    label="验证 macOS bundle 签名",
                ),
                Command(
                    ("codesign", "--display", "--verbose=4", bundle),
                    root,
                    label="读取 macOS bundle 签名证据",
                    capture_output=True,
                ),
            ]
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
            command.argv,
            cwd=command.cwd,
            env=environment,
            check=True,
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
    return {
        "head": head,
        "dirty": bool(status),
        "status": status,
        "tracked_diff_sha256": hashlib.sha256(diff).hexdigest(),
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


def validate_bundle(
    root: Path, target: Target
) -> tuple[list[dict[str, object]], list[dict[str, object]], list[dict[str, object]]]:
    source_paths = [root / target.core_path]
    if target.needs_helper:
        source_paths.append(root / "libclash/windows/BettboxHelperService.exe")
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


def execute_build(root: Path, target: Target) -> None:
    started_at = datetime.now(timezone.utc).isoformat()
    lock_snapshot = snapshot_locks(root)
    source_before = git_source_state(root)
    core_path = root / target.core_path
    placeholder = "<core-sha256>"
    initial_commands = command_plan(root, target, placeholder)[:2]
    run_commands(initial_commands)
    if not core_path.is_file():
        raise RuntimeError(f"core 产物不存在：{target.core_path.as_posix()}")
    core_sha256 = sha256_file(core_path)
    plan = command_plan(root, target, core_sha256)
    signature_evidence: list[str] = []
    if target.needs_helper:
        run_commands(plan[2:3])
        copy_windows_helper(root)
        run_commands(plan[3:])
    else:
        run_commands(plan[2:4])
        signature_outputs = run_commands(plan[4:])
        signature_evidence = parse_adhoc_signature(signature_outputs[-1] or "")

    source_after = git_source_state(root)
    locks_unchanged = all(
        (root / path).is_file() and sha256_file(root / path) == digest
        for path, digest in lock_snapshot.items()
    )
    sources, bundle_files, bindings = validate_bundle(root, target)
    source_unchanged = source_state_unchanged(source_before, source_after)
    manifest = {
        "schema_version": 1,
        "target": target.name,
        "started_at": started_at,
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "commands_succeeded": True,
        "source_unchanged": source_unchanged,
        "locks_unchanged": locks_unchanged,
        "source_before": source_before,
        "source_after": source_after,
        "lock_sha256": {
            path.as_posix(): digest for path, digest in sorted(lock_snapshot.items())
        },
        "source_artifacts": sources,
        "bundle_path": target.bundle_path.as_posix(),
        "bundle_files": bundle_files,
        "bundle_bindings": bindings,
        "signature_evidence": signature_evidence,
    }
    manifest_path = write_manifest(root, target, manifest)
    print(f"验证清单：{manifest_path.relative_to(root).as_posix()}")
    for artifact in sources:
        print(f"  {artifact['sha256']}  {artifact['path']}")
    if not locks_unchanged:
        raise RuntimeError("构建期间依赖锁文件发生变化，验证清单已记录")
    if not source_unchanged:
        raise RuntimeError("构建期间候选源码状态发生变化，验证清单已记录")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=sorted(TARGETS), required=True)
    parser.add_argument(
        "--execute",
        action="store_true",
        help="通过前置检查后执行不打包、不发布的原生编译",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = repository_root()
    target = TARGETS[args.target]
    if not (root / "pubspec.yaml").is_file():
        raise RuntimeError(f"无法识别 Bettbox 仓库根目录：{root}")

    validate_host(target, platform.system(), platform.machine())
    snapshot_locks(root)
    versions = check_tool_versions(root, target)
    mode = "执行" if args.execute else "preflight/dry-run"
    print(f"目标：{target.name}；模式：{mode}")
    print("工具版本：" + "，".join(f"{key} {value}" for key, value in versions.items()))
    print("命令计划：")
    for command in command_plan(root, target, "<core-sha256>"):
        print(f"  {display_command(command, root)}")

    if args.execute:
        execute_build(root, target)
    else:
        print("preflight 完成；未执行编译。传入 --execute 后才会构建。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"错误：{error}", file=sys.stderr)
        raise SystemExit(1) from error
