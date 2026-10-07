#!/usr/bin/env python3
"""从固定公开源快照准备 macOS production supervisor 与最终身份。"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import uuid
from pathlib import Path

from macos_core_identity import open_public_file, check_public_binding, hash_bound_file

IDENTIFIER = "com.appshub.bettbox.core.supervisor"
EXECUTABLE = Path("libclash/macos/BettboxCoreSupervisor")
IDENTITY_PATH = Path("libclash/macos/BettboxCoreSupervisorIdentity.json")
SOURCE_ROOT = Path("macos/CoreSupervisor")
SOURCE_FILES = (
    "Bridge.h", "Identity/SSIAuthority.swift", "Identity/SSIAppleBackend.swift",
    "Identity/SSIFile.swift", "Identity/SSIBridge.h", "Owner/OwnedBackend.c",
    "Owner/OwnedBackend.h", "Owner/SystemBackend.swift", "Owner/SupervisorLifecycle.swift",
    "Relay/HelperC.c", "Relay/HelperC.h", "Relay/RelayCodec.swift", "Relay/SDKMailbox.swift",
    "Relay/RelayMain.swift", "Relay/main.swift",
)
SWIFT_FILES = tuple(name for name in SOURCE_FILES if name.endswith(".swift"))
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
TARGET = "arm64-apple-macos12"


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode)


def directory_fd(root: Path, relative: Path):
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("固定目录越界")
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in relative.parts:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def regular_destination(directory: int, name: str):
    try:
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError("固定产物不允许链接或特殊文件")


def write_file(directory: int, name: str, data: bytes, mode=0o600):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         mode, dir_fd=directory)
    try:
        offset = 0
        while offset < len(data):
            count = os.write(descriptor, data[offset:])
            if count <= 0:
                raise RuntimeError("公开文件写入无进展")
            offset += count
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def read_bound(root: Path, relative: Path, limit=None) -> bytes:
    descriptor, parent, before = open_public_file(root, relative)
    try:
        if limit is not None and before.st_size > limit:
            raise RuntimeError("公开文件输入过大")
        chunks = []
        while chunk := os.read(descriptor, 1024 * 1024):
            chunks.append(chunk)
        after = check_public_binding(root, relative, descriptor, parent, before)
        if fingerprint(before) != fingerprint(after):
            raise RuntimeError("公开源在冻结期间变化")
        return b"".join(chunks)
    finally:
        os.close(descriptor)
        os.close(parent)


def source_hashes(root: Path, base=SOURCE_ROOT):
    result = {}
    for name in SOURCE_FILES:
        descriptor, directory, before = open_public_file(root, base / name)
        try:
            result[name] = hash_bound_file(descriptor)
            after = check_public_binding(root, base / name, descriptor, directory, before)
            if fingerprint(before) != fingerprint(after):
                raise RuntimeError("公开源摘要漂移")
        finally:
            os.close(descriptor)
            os.close(directory)
    return result


def snapshot(root: Path, stage: Path, expected):
    stage_fd = directory_fd(root, stage)
    try:
        os.mkdir("source", mode=0o700, dir_fd=stage_fd)
    finally:
        os.close(stage_fd)
    base = stage / "source"
    base_fd = directory_fd(root, base)
    try:
        for name in ("Identity", "Owner", "Relay"):
            os.mkdir(name, mode=0o700, dir_fd=base_fd)
    finally:
        os.close(base_fd)
    for name in SOURCE_FILES:
        data = read_bound(root, SOURCE_ROOT / name)
        if hashlib.sha256(data).hexdigest() != expected[name]:
            raise RuntimeError("公开源复制摘要漂移")
        relative = Path(name)
        directory = directory_fd(root, base / relative.parent)
        try:
            write_file(directory, relative.name, data)
        finally:
            os.close(directory)
    if source_hashes(root, base) != expected or source_hashes(root) != expected:
        raise RuntimeError("冻结快照摘要漂移")
    return base


def compile_arguments(stage: Path, source: Path):
    # 全部源、头文件及对象来自固定冻结快照，不启用 fixture 条件编译。
    clang = ("/usr/bin/xcrun", "--sdk", "macosx", "clang", "-target", TARGET,
             "-Wall", "-Wextra", "-Werror", "-I", source.as_posix())
    commands = [
        (*clang, "-c", (source / "Owner/OwnedBackend.c").as_posix(), "-o", (stage / "owned.o").as_posix()),
        (*clang, "-c", (source / "Relay/HelperC.c").as_posix(), "-o", (stage / "relay.o").as_posix()),
        ("/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-target", TARGET,
         "-I", source.as_posix(), "-import-objc-header", (source / "Relay/HelperC.h").as_posix(),
         *((source / name).as_posix() for name in SWIFT_FILES),
         (stage / "owned.o").as_posix(), (stage / "relay.o").as_posix(),
         "-framework", "Security", "-framework", "Foundation", "-lproc",
         "-o", (stage / EXECUTABLE.name).as_posix()),
    ]
    return commands


def signing_arguments(relative: Path):
    return [
        ("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", IDENTIFIER, relative.as_posix()),
        ("/usr/bin/codesign", "--verify", "--strict", relative.as_posix()),
        ("/usr/bin/codesign", "--display", "--verbose=4", relative.as_posix()),
    ]


def run_commands(root: Path, arguments):
    results = []
    for argv in arguments:
        if argv[0] not in {"/usr/bin/xcrun", "/usr/bin/codesign"}:
            raise RuntimeError("工具白名单拒绝")
        try:
            result = subprocess.run(argv, cwd=root, env=ENV, check=False,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            raise RuntimeError("固定工具不可用或超时") from None
        if result.returncode:
            raise RuntimeError("固定工具失败")
        results.append(result.stdout if argv[1] == "--display" else None)
    return results


def parse_signature(output: str):
    fields = {}
    for line in output.splitlines():
        key, separator, value = line.strip().partition("=")
        if separator and key in {"Identifier", "CDHash", "Signature", "TeamIdentifier"}:
            if key in fields:
                raise RuntimeError("supervisor 签名公开字段重复")
            fields[key] = value
    if fields.get("Identifier") != IDENTIFIER or fields.get("Signature") != "adhoc" or \
            fields.get("TeamIdentifier") != "not set" or not re.fullmatch(r"[0-9a-f]{40}", fields.get("CDHash", "")):
        raise RuntimeError("supervisor 固定身份无效")
    return {"schema": 1, "identifier": IDENTIFIER, "cdhash": fields["CDHash"], "signingmode": "adhoc"}


def validate_identity(value):
    if not isinstance(value, dict) or set(value) != {"schema", "identifier", "cdhash", "signingmode", "sha256"} or \
            type(value.get("schema")) is not int or value["schema"] != 1 or \
            value.get("identifier") != IDENTIFIER or value.get("signingmode") != "adhoc" or \
            not isinstance(value.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) or \
            not isinstance(value.get("cdhash"), str) or not re.fullmatch(r"[0-9a-f]{40}", value["cdhash"]):
        raise RuntimeError("supervisor 身份 manifest 字段无效")
    return value


def read_identity(root: Path):
    data = read_bound(root, IDENTITY_PATH, 4096)
    if len(data) > 4096:
        raise RuntimeError("supervisor 身份 manifest 太大")
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise RuntimeError("supervisor 身份 manifest 字段重复")
            result[key] = value
        return result
    try:
        identity = validate_identity(json.loads(data, object_pairs_hook=unique_pairs))
    except (ValueError, UnicodeError):
        raise RuntimeError("supervisor 身份 JSON 无效") from None
    canonical = (json.dumps(identity, sort_keys=True) + "\n").encode()
    if canonical != data:
        raise RuntimeError("supervisor 身份 manifest 非规范编码")
    return identity, data


def sign_and_freeze(root: Path, relative: Path, runner):
    original, original_parent, _ = open_public_file(root, relative)
    try:
        commands = signing_arguments(relative)
        if len(runner(commands[:1])) != 1:
            raise RuntimeError("supervisor 签名回执无效")
        descriptor, directory, before = open_public_file(root, relative)
        try:
            inode = lambda info: (info.st_dev, info.st_ino, info.st_mode)
            if inode(os.fstat(directory)) != inode(os.fstat(original_parent)):
                raise RuntimeError("supervisor 签名父目录漂移")
            outputs = runner(commands[1:])
            if len(outputs) != 2:
                raise RuntimeError("supervisor 验签回执无效")
            after = check_public_binding(root, relative, descriptor, directory, before)
            if fingerprint(before) != fingerprint(after):
                raise RuntimeError("supervisor 验签摘要漂移")
            result = parse_signature(outputs[-1] or "")
            result["sha256"] = hash_bound_file(descriptor)
            after = check_public_binding(root, relative, descriptor, directory, before)
            if fingerprint(before) != fingerprint(after):
                raise RuntimeError("supervisor 验签后摘要漂移")
            return validate_identity(result), descriptor, directory, before
        except Exception:
            os.close(descriptor)
            os.close(directory)
            raise
    finally:
        os.close(original)
        os.close(original_parent)


def prepare_supervisor_artifact(root: Path, runner=None):
    runner = runner or (lambda commands: run_commands(root, commands))
    parent = directory_fd(root, EXECUTABLE.parent)
    stage_name = ".supervisor-build-" + uuid.uuid4().hex
    stage = EXECUTABLE.parent / stage_name
    stage_fd = None
    descriptor = signed_parent = None
    committing = False
    try:
        regular_destination(parent, EXECUTABLE.name)
        regular_destination(parent, IDENTITY_PATH.name)
        os.mkdir(stage_name, mode=0o700, dir_fd=parent)
        stage_fd = directory_fd(root, stage)
        baseline = source_hashes(root)
        write_file(stage_fd, "SOURCE_BASE.json", (json.dumps({"target": TARGET, "source_hashes_before": baseline}, sort_keys=True) + "\n").encode())
        source = snapshot(root, stage, baseline)
        commands = compile_arguments(stage, source)
        if len(runner(commands)) != len(commands):
            raise RuntimeError("supervisor 编译回执无效")
        if source_hashes(root) != baseline or source_hashes(root, source) != baseline:
            raise RuntimeError("supervisor 编译源摘要漂移")
        relative = stage / EXECUTABLE.name
        result, descriptor, signed_parent, before = sign_and_freeze(root, relative, runner)
        final_sources = source_hashes(root)
        if final_sources != baseline or source_hashes(root, source) != baseline:
            raise RuntimeError("supervisor 发布源摘要漂移")
        write_file(stage_fd, "SOURCE_RESULT.json", (json.dumps({"target": TARGET, "source_hashes_after": final_sources}, sort_keys=True) + "\n").encode())
        if (os.fstat(stage_fd).st_dev, os.fstat(stage_fd).st_ino) != (os.fstat(signed_parent).st_dev, os.fstat(signed_parent).st_ino):
            raise RuntimeError("supervisor 暂存目录漂移")
        current_parent = directory_fd(root, EXECUTABLE.parent)
        try:
            if fingerprint(os.fstat(current_parent))[:2] != fingerprint(os.fstat(parent))[:2]:
                raise RuntimeError("supervisor 发布父目录漂移")
        finally:
            os.close(current_parent)
        regular_destination(parent, EXECUTABLE.name)
        regular_destination(parent, IDENTITY_PATH.name)
        after = check_public_binding(root, relative, descriptor, signed_parent, before)
        if fingerprint(before) != fingerprint(after) or hash_bound_file(descriptor) != result["sha256"]:
            raise RuntimeError("supervisor 发布摘要漂移")
        data = (json.dumps(result, sort_keys=True) + "\n").encode()
        write_file(stage_fd, IDENTITY_PATH.name, data)
        # 两个文件不能组成一个原子事务：先撤去成功标记，再提交 binary，最后提交 manifest。
        # 路径式编译/签名和双文件发布不提供同 UID 对抗性硬隔离。
        committing = True
        try:
            os.unlink(IDENTITY_PATH.name, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.replace(EXECUTABLE.name, EXECUTABLE.name, src_dir_fd=stage_fd, dst_dir_fd=parent)
        published = check_public_binding(root, EXECUTABLE, descriptor, parent, before)
        if fingerprint(before) != fingerprint(published) or hash_bound_file(descriptor) != result["sha256"]:
            raise RuntimeError("supervisor 已发布产物摘要漂移")
        os.fsync(parent)
        os.replace(IDENTITY_PATH.name, IDENTITY_PATH.name, src_dir_fd=stage_fd, dst_dir_fd=parent)
        os.fsync(parent)
        parsed, canonical = read_identity(root)
        if parsed != result or canonical != data:
            raise RuntimeError("supervisor 已发布身份漂移")
        committing = False
        return result
    except Exception:
        if committing:
            try:
                os.unlink(IDENTITY_PATH.name, dir_fd=parent)
                os.fsync(parent)
            except FileNotFoundError:
                pass
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if signed_parent is not None:
            os.close(signed_parent)
        if stage_fd is not None:
            os.close(stage_fd)
        os.close(parent)
        # 仅保留固定目录内的冻结快照供主控验收，不自动清理或执行这些文件。


def main(argv=None):
    parser = argparse.ArgumentParser(description="准备固定 macOS production supervisor")
    parser.add_argument("--prepare", action="store_true", required=True)
    parser.parse_args(argv)
    try:
        identity = prepare_supervisor_artifact(Path(__file__).resolve().parents[1])
    except Exception:
        print("macOS supervisor 产物准备失败")
        return 1
    print(json.dumps(identity, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
