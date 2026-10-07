"""仅向本项目独立 Gradle home 预置已核验的官方发行 ZIP（POSIX）。"""
from __future__ import annotations

import hashlib
import math
import os
import re
import stat
import time
import uuid
from pathlib import Path

# 官方来源：https://gradle.org/release-checksums/；主控已核对官方 TLS 下载。
DISTRIBUTION_URL = "https://services.gradle.org/distributions/gradle-8.14-all.zip"
DISTRIBUTION_BYTES = 224116304
DISTRIBUTION_SHA256 = "efe9a3d147d948d7528a9887fa35abcf24ca1a43ad06439996490f77569b02d1"
URL_HASH = "c2qonpi39x1mddn7hk5gh9iqj"
ZIP_NAME = "gradle-8.14-all.zip"
RELATIVE_DIRECTORY = ("wrapper", "dists", "gradle-8.14-all", URL_HASH)
HOME_PATTERN = re.compile(r"gradle-home-[A-Za-z0-9_-]{1,64}\Z")
MAX_ENTRIES = 512
MAX_HOMES = 64
CHUNK_BYTES = 1024 * 1024
SEED_SECONDS = 120
ERROR = "Gradle 发行 ZIP 预置未通过安全校验"


class DistributionCacheError(RuntimeError):
    """固定诊断，不包含路径、输入或底层异常正文。"""


def _fail() -> None:
    raise DistributionCacheError(ERROR)


def _check(end: float) -> None:
    if time.monotonic() >= end:
        _fail()


def _fingerprint(value: os.stat_result) -> tuple[int, ...]:
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def _directory(fd: int, *, private: bool = False) -> None:
    value = os.fstat(fd)
    if not stat.S_ISDIR(value.st_mode):
        _fail()
    if private and (value.st_uid != os.getuid() or value.st_mode & 0o077):
        _fail()


def _open_directory(parent: int, name: str, *, private: bool = False) -> int:
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        _directory(fd, private=private)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _absolute_directory(path: Path) -> int:
    # 仅父路径允许平台 canonical 化；实际根及其后续组件均不跟随链接。
    parent = path.parent.resolve(strict=True)
    canonical = parent / path.name
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in canonical.parts[1:]:
            next_fd = _open_directory(fd, component)
            os.close(fd)
            fd = next_fd
        value = os.fstat(fd)
        if value.st_uid != os.getuid() or value.st_mode & 0o022:
            _fail()
        return fd
    except BaseException:
        os.close(fd)
        raise


def _walk(parent: int, parts: tuple[str, ...], *, create: bool = False) -> int:
    fd = os.dup(parent)
    try:
        for component in parts:
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            next_fd = _open_directory(fd, component)
            value = os.fstat(next_fd)
            if value.st_uid != os.getuid() or value.st_mode & 0o022:
                os.close(next_fd)
                _fail()
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _file(parent: int, name: str) -> tuple[int, tuple[int, ...]]:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        value = os.fstat(fd)
        if (not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid()
                or value.st_mode & 0o022 or value.st_nlink != 1):
            _fail()
        return fd, _fingerprint(value)
    except BaseException:
        os.close(fd)
        raise


def _same_file(parent: int, name: str, fd: int, baseline: tuple[int, ...]) -> None:
    if _fingerprint(os.fstat(fd)) != baseline:
        _fail()
    check_fd, current = _file(parent, name)
    try:
        if current != baseline:
            _fail()
    finally:
        os.close(check_fd)


def _url_hash(url: str) -> str:
    # 已核验官方 ZIP 的 src/wrapper-shared/.../PathAssembler.java：
    # safeUri().toASCIIString() 的 UTF-8 MD5 → 无符号 BigInteger → base36。
    # 固定 URL 为 ASCII、无 userinfo，MD5 仅用于目录命名，信任使用 SHA-256。
    number = int.from_bytes(hashlib.md5(url.encode("utf-8")).digest(), "big")
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    result = ""
    while number:
        number, remainder = divmod(number, 36)
        result = digits[remainder] + result
    return result or "0"


def _properties(root_fd: int, end: float) -> None:
    directory = _walk(root_fd, ("android", "gradle", "wrapper"))
    try:
        fd, baseline = _file(directory, "gradle-wrapper.properties")
        try:
            if baseline[5] > 4096:
                _fail()
            raw = os.read(fd, 4097)
            _check(end)
            _same_file(directory, "gradle-wrapper.properties", fd, baseline)
        finally:
            os.close(fd)
    finally:
        os.close(directory)
    values: dict[str, str] = {}
    for line in raw.decode("ascii").splitlines():
        if not line.strip() or line.lstrip().startswith(("#", "!")):
            continue
        key, separator, value = line.partition("=")
        if not separator or key in values or key != key.strip():
            _fail()
        values[key] = value
    expected = {"distributionBase": "GRADLE_USER_HOME", "distributionPath": "wrapper/dists",
                "zipStoreBase": "GRADLE_USER_HOME", "zipStorePath": "wrapper/dists",
                "distributionUrl": DISTRIBUTION_URL.replace(":", "\\:", 1),
                "distributionSha256Sum": DISTRIBUTION_SHA256}
    if values != expected or _url_hash(DISTRIBUTION_URL) != URL_HASH:
        _fail()


def _source(build_fd: int, current: str, end: float) -> tuple[str, int, int, tuple[int, ...]] | None:
    entries = []
    with os.scandir(build_fd) as iterator:
        for entry in iterator:
            _check(end)
            entries.append(entry.name)
            if len(entries) > MAX_ENTRIES:
                _fail()
    homes = sorted(name for name in entries if HOME_PATTERN.fullmatch(name) and name != current)
    if len(homes) > MAX_HOMES:
        _fail()
    found = None
    try:
        # 名称有界排序；元数据只确定一份来源，不赋予内容信任。
        for name in homes:
            _check(end)
            home_fd = _open_directory(build_fd, name, private=True)
            directory = None
            try:
                try:
                    directory = _walk(home_fd, RELATIVE_DIRECTORY)
                    fd, baseline = _file(directory, ZIP_NAME)
                except FileNotFoundError:
                    continue
                found = (name, directory, fd, baseline)
                directory = None
                break
            finally:
                if directory is not None:
                    os.close(directory)
                os.close(home_fd)
        return found
    except BaseException:
        if found is not None:
            os.close(found[2])
            os.close(found[1])
        raise


def _copy(source: int, target: int, end: float) -> tuple[int, ...]:
    digest = hashlib.sha256()
    total = 0
    while True:
        _check(end)
        block = os.read(source, CHUNK_BYTES)
        if not block:
            break
        total += len(block)
        if total > DISTRIBUTION_BYTES:
            _fail()
        digest.update(block)
        # 短写作为失败；绝不发布不完整副本。
        if os.write(target, block) != len(block):
            _fail()
    if total != DISTRIBUTION_BYTES or digest.hexdigest() != DISTRIBUTION_SHA256:
        _fail()
    _check(end)
    os.fsync(target)
    verified_stat = _fingerprint(os.fstat(target))
    os.lseek(target, 0, os.SEEK_SET)
    written = hashlib.sha256()
    total = 0
    while True:
        _check(end)
        block = os.read(target, CHUNK_BYTES)
        if not block:
            break
        total += len(block)
        if total > DISTRIBUTION_BYTES:
            _fail()
        written.update(block)
    if (total != DISTRIBUTION_BYTES or written.hexdigest() != DISTRIBUTION_SHA256
            or _fingerprint(os.fstat(target)) != verified_stat):
        _fail()
    return verified_stat


def seed_distribution_zip(root: Path, owned_home: Path, deadline: float) -> dict:
    """只复制发行 ZIP；固定诊断失败，未发现来源时沿用官方下载。"""
    root_fd = build_fd = target_home_fd = source_dir = source_fd = target_dir = temp_fd = None
    temporary = None
    published = False
    try:
        if not math.isfinite(deadline):
            _fail()
        end = min(deadline, time.monotonic() + SEED_SECONDS)
        _check(end)
        relative = Path(os.path.abspath(owned_home)).relative_to(Path(os.path.abspath(root)))
        if (len(relative.parts) != 3 or relative.parts[:2] != (".test", "android-build")
                or not HOME_PATTERN.fullmatch(relative.parts[2])):
            _fail()
        root_fd = _absolute_directory(Path(os.path.abspath(root)))
        build_fd = _walk(root_fd, (".test", "android-build"))
        target_home_fd = _open_directory(build_fd, relative.parts[2], private=True)
        target_identity = _fingerprint(os.fstat(target_home_fd))[:2]
        root_identity = _fingerprint(os.fstat(root_fd))[:2]
        build_identity = _fingerprint(os.fstat(build_fd))[:2]
        found = _source(build_fd, relative.parts[2], end)
        if found is None:
            return {"reused": False}
        name, source_dir, source_fd, baseline = found
        if baseline[5] != DISTRIBUTION_BYTES:
            _fail()
        _properties(root_fd, end)
        target_dir = _walk(target_home_fd, RELATIVE_DIRECTORY, create=True)
        try:
            os.stat(ZIP_NAME, dir_fd=target_dir, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _fail()
        temporary = ".bettbox-distribution-" + uuid.uuid4().hex
        temp_fd = os.open(temporary, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                          0o600, dir_fd=target_dir)
        target_baseline = _copy(source_fd, temp_fd, end)
        _same_file(source_dir, ZIP_NAME, source_fd, baseline)
        # 重新从锚定根走目录，拒绝复制期间的父目录替换；不重定义基线。
        fresh_root = _absolute_directory(Path(os.path.abspath(root)))
        try:
            if _fingerprint(os.fstat(fresh_root))[:2] != root_identity:
                _fail()
            fresh_build = _walk(fresh_root, (".test", "android-build"))
            try:
                if _fingerprint(os.fstat(fresh_build))[:2] != build_identity:
                    _fail()
                fresh_source_home = _open_directory(fresh_build, name, private=True)
                try:
                    fresh_source = _walk(fresh_source_home, RELATIVE_DIRECTORY)
                    try:
                        if _fingerprint(os.fstat(fresh_source))[:2] != _fingerprint(os.fstat(source_dir))[:2]:
                            _fail()
                        _same_file(fresh_source, ZIP_NAME, source_fd, baseline)
                    finally:
                        os.close(fresh_source)
                finally:
                    os.close(fresh_source_home)
            finally:
                os.close(fresh_build)
        finally:
            os.close(fresh_root)
        _properties(root_fd, end)
        check_home = _open_directory(build_fd, relative.parts[2], private=True)
        try:
            if _fingerprint(os.fstat(check_home))[:2] != target_identity:
                _fail()
            check_target = _walk(check_home, RELATIVE_DIRECTORY)
            try:
                if _fingerprint(os.fstat(check_target))[:2] != _fingerprint(os.fstat(target_dir))[:2]:
                    _fail()
                temp_baseline = target_baseline
                _same_file(target_dir, temporary, temp_fd, temp_baseline)
                _check(end)
                # 同目录硬链接仅用于无覆盖原子发布；不与来源共享 inode。
                os.link(temporary, ZIP_NAME, src_dir_fd=target_dir, dst_dir_fd=target_dir,
                        follow_symlinks=False)
                published = True
                os.fsync(target_dir)
                target_stat = os.stat(ZIP_NAME, dir_fd=target_dir, follow_symlinks=False)
                if (target_stat.st_dev, target_stat.st_ino) != temp_baseline[:2]:
                    _fail()
                os.unlink(temporary, dir_fd=target_dir)
                temporary = None
                os.fsync(target_dir)
                final_baseline = _fingerprint(os.fstat(temp_fd))
                # link/unlink 会改变 ctime/nlink，其余已验证内容身份不得变化。
                if (final_baseline[:4] != temp_baseline[:4]
                        or final_baseline[5:7] != temp_baseline[5:7]
                        or final_baseline[4] != 1):
                    _fail()
                _same_file(target_dir, ZIP_NAME, temp_fd, final_baseline)
                _check(end)
            finally:
                os.close(check_target)
        finally:
            os.close(check_home)
        return {"reused": True, "source": "project-task-gradle-home",
                "bytes": DISTRIBUTION_BYTES, "sha256": DISTRIBUTION_SHA256}
    except Exception:
        # 发布后的异常亦不得伪报成功；仅移除仍指向本轮 inode 的副本。
        if published and target_dir is not None and temp_fd is not None:
            try:
                owned = os.fstat(temp_fd)
                current = os.stat(ZIP_NAME, dir_fd=target_dir, follow_symlinks=False)
                if (owned.st_dev, owned.st_ino) == (current.st_dev, current.st_ino):
                    os.unlink(ZIP_NAME, dir_fd=target_dir)
                    os.fsync(target_dir)
            except OSError:
                pass
        raise DistributionCacheError(ERROR) from None
    finally:
        if temporary is not None and target_dir is not None and temp_fd is not None:
            try:
                owned = os.fstat(temp_fd)
                current = os.stat(temporary, dir_fd=target_dir, follow_symlinks=False)
                if (owned.st_dev, owned.st_ino) == (current.st_dev, current.st_ino):
                    os.unlink(temporary, dir_fd=target_dir)
            except OSError:
                pass
        for fd in (temp_fd, target_dir, source_fd, source_dir, target_home_fd, build_fd, root_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
