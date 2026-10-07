#!/usr/bin/env python3
"""macOS 开发 core 的共享最终签名与公开身份准备入口。"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path

CORE_IDENTIFIER = "com.appshub.bettbox.core"
CORE_EXECUTABLE = Path("libclash/macos/BettboxCore")
CORE_IDENTITY_PATH = Path("libclash/macos/BettboxCoreIdentity.json")


def core_signing_arguments() -> list[tuple[str, ...]]:
    core = CORE_EXECUTABLE.as_posix()
    return [
        ("codesign", "--force", "--sign", "-", "--identifier", CORE_IDENTIFIER, core),
        ("codesign", "--verify", "--strict", core),
        ("codesign", "--display", "--verbose=4", core),
    ]


def public_parents(root: Path, path: Path) -> dict[str, tuple[int, ...]]:
    if not path.is_relative_to(root):
        raise RuntimeError("公开产物路径越界")
    result = {}
    for parent in (path, *path.parents):
        if parent == root:
            break
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise RuntimeError("公开产物父目录无效")
        result[str(parent)] = (info.st_dev, info.st_ino, info.st_mode)
    return result


def open_public_file(root: Path, relative: Path):
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise RuntimeError("公开产物路径越界")
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptor = None
    try:
        for part in relative.parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError("公开产物不是普通文件")
        return descriptor, directory, before
    except Exception:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)
        raise


def check_public_binding(root: Path, relative: Path, descriptor: int, directory: int, before):
    current, parent, info = open_public_file(root, relative)
    try:
        inode = lambda item: (item.st_dev, item.st_ino, item.st_mode)
        if inode(os.fstat(descriptor)) != inode(before) or inode(info) != inode(before) or \
                inode(os.fstat(parent)) != inode(os.fstat(directory)):
            raise RuntimeError("公开产物身份发生漂移")
        return os.fstat(descriptor)
    finally:
        os.close(current)
        os.close(parent)


def hash_bound_file(descriptor: int) -> str:
    before = os.fstat(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(descriptor)
    fingerprint = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_mode)
    if fingerprint(before) != fingerprint(after):
        raise RuntimeError("公开产物在冻结期间变化")
    return digest.hexdigest()


def stable_core_hash(root: Path) -> str:
    descriptor, directory, before = open_public_file(root, CORE_EXECUTABLE)
    try:
        result = hash_bound_file(descriptor)
        check_public_binding(root, CORE_EXECUTABLE, descriptor, directory, before)
        return result
    finally:
        os.close(descriptor)
        os.close(directory)


def run_identity_commands(root: Path, arguments):
    # 只使用系统 codesign 与固定 ad hoc 身份，不继承凭据环境。
    outputs = []
    for argv in arguments:
        command = ("/usr/bin/codesign", *argv[1:])
        result = subprocess.run(command, cwd=root, env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                                check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        outputs.append(result.stdout if argv[1] == "--display" else None)
    return outputs


def parse_core_signature(output: str) -> dict[str, object]:
    # 仅抽取固定公开字段；不保留 codesign 原文、路径或其它诊断。
    fields: dict[str, str] = {}
    for line in output.splitlines():
        key, separator, value = line.strip().partition("=")
        if separator and key in {"Identifier", "CDHash", "Signature", "TeamIdentifier"}:
            if key in fields:
                raise RuntimeError("core 签名公开字段重复")
            fields[key] = value
    if fields.get("Identifier") != CORE_IDENTIFIER or fields.get("Signature") != "adhoc" or \
            fields.get("TeamIdentifier") != "not set" or not re.fullmatch(r"[0-9a-f]{40}", fields.get("CDHash", "")):
        raise RuntimeError("core 不是预期的固定身份 ad hoc 签名")
    return {"schema": 1, "identifier": CORE_IDENTIFIER, "cdhash": fields["CDHash"], "signingmode": "adhoc"}


def validate_core_identity(value: object) -> dict[str, object]:
    keys = {"schema", "sha256", "identifier", "cdhash", "signingmode"}
    if not isinstance(value, dict) or set(value) != keys or type(value.get("schema")) is not int or value["schema"] != 1 or \
            value.get("identifier") != CORE_IDENTIFIER or value.get("signingmode") != "adhoc" or \
            not isinstance(value.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) or \
            not isinstance(value.get("cdhash"), str) or not re.fullmatch(r"[0-9a-f]{40}", value["cdhash"]):
        raise RuntimeError("core 身份 manifest 字段无效")
    return value


def read_core_identity(root: Path, relative: Path) -> tuple[dict[str, object], bytes]:
    descriptor, directory, before = open_public_file(root, relative)
    try:
        if before.st_size > 4096:
            raise RuntimeError("core 身份 manifest 输入无效")
        data = os.read(descriptor, 4097)
        after = check_public_binding(root, relative, descriptor, directory, before)
        fingerprint = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_mode)
        if len(data) != before.st_size or fingerprint(before) != fingerprint(after):
            raise RuntimeError("core 身份 manifest 在读取期间变化")
    finally:
        os.close(descriptor)
        os.close(directory)
    def unique_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result = {}
        for key, value in pairs:
            if key in result:
                raise RuntimeError("core 身份 manifest 字段重复")
            result[key] = value
        return result
    try:
        value = json.loads(data, object_pairs_hook=unique_pairs)
    except (ValueError, UnicodeError):
        raise RuntimeError("core 身份 manifest JSON 无效") from None
    return validate_core_identity(value), data


def prepare_core_identity(root: Path, runner=None) -> dict[str, object]:
    # 路径式codesign签名可能正常替换inode。前置拒绝静态链接/特殊文件，
    # 仅允许签名阶段换产物；签后重新持FD，再独立verify/display冻结身份。
    # 同UID在路径调用窗口替换后还原不被硬隔离；不声称codesign绑定了FD。
    signer = runner or (lambda args: run_identity_commands(root, args))
    arguments = core_signing_arguments()
    original, original_parent, _ = open_public_file(root, CORE_EXECUTABLE)
    try:
        sign_outputs = signer(arguments[:1])
        if len(sign_outputs) != 1:
            raise RuntimeError("core 签名阶段回执无效")
        descriptor, directory, before = open_public_file(root, CORE_EXECUTABLE)
        try:
            inode = lambda item: (item.st_dev, item.st_ino, item.st_mode)
            if inode(os.fstat(directory)) != inode(os.fstat(original_parent)):
                raise RuntimeError("签名阶段 core 父目录身份发生漂移")
            # before是签名后的新基线；验证阶段不得再接受inode或内容变化。
            outputs = signer(arguments[1:])
            if len(outputs) != 2:
                raise RuntimeError("core 验签阶段回执无效")
            signed = check_public_binding(root, CORE_EXECUTABLE, descriptor, directory, before)
            fingerprint = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_mode)
            if fingerprint(before) != fingerprint(signed):
                raise RuntimeError("验签阶段 core 内容发生漂移")
            identity = parse_core_signature(outputs[-1] or "")
            identity["sha256"] = hash_bound_file(descriptor)
            after = check_public_binding(root, CORE_EXECUTABLE, descriptor, directory, before)
            if fingerprint(signed) != fingerprint(after):
                raise RuntimeError("签后 core 在摘要绑定期间变化")
        finally:
            os.close(descriptor)
            os.close(directory)
    finally:
        os.close(original)
        os.close(original_parent)
    validate_core_identity(identity)
    # 通过逐层 no-follow 目录句柄发布公开生成文件，避免链接写入越界。
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = ".BettboxCoreIdentity.json.tmp-" + str(os.getpid())
    created = False
    try:
        for part in CORE_IDENTITY_PATH.parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        created = True
        try:
            data = (json.dumps(identity, sort_keys=True) + "\n").encode("utf-8")
            offset = 0
            while offset < len(data):
                written = os.write(descriptor, data[offset:])
                if written <= 0:
                    raise RuntimeError("core 身份 manifest 写入无进展")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            existing = os.stat(CORE_IDENTITY_PATH.name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and not stat.S_ISREG(existing.st_mode):
            raise RuntimeError("core 身份 manifest 不允许链接或特殊文件")
        os.replace(temporary, CORE_IDENTITY_PATH.name, src_dir_fd=directory, dst_dir_fd=directory)
        created = False
        os.fsync(directory)
    finally:
        if created:
            os.unlink(temporary, dir_fd=directory)
        os.close(directory)
    return identity


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="准备固定 macOS core 的最终 ad hoc 身份")
    parser.add_argument("--prepare", action="store_true", required=True, help="显式准备固定 core 的最终身份")
    parser.parse_args(argv)
    try:
        identity = prepare_core_identity(Path(__file__).resolve().parents[1])
    except Exception:
        print("macOS core 身份准备失败")
        return 1
    # 只输出固定schema的公开元数据，Dart调用者必须验证退出码与JSON。
    print(json.dumps(identity, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
