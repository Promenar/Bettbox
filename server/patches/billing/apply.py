#!/usr/bin/env python3
"""候选源码补丁：默认仅校验，不执行数据库迁移或启动服务。"""
import argparse
import hashlib
import json
import os
import stat
import time
from pathlib import Path


FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parts(relative):
    value = Path(relative)
    if value.is_absolute() or not value.parts or any(p in ('..', '.', '') for p in value.parts):
        raise RuntimeError('补丁路径不合法')
    return value.parts


class Tree:
    """逐级无链接打开目录；所有读写均相对于目录句柄。"""
    def __init__(self, root):
        self.root = Path(os.path.abspath(root))
        self.identity = None
        fd = self.parent('sentinel', False)
        try:
            self.identity = self.ident(fd)
        finally:
            os.close(fd)

    @staticmethod
    def ident(fd):
        info = os.fstat(fd)
        return info.st_dev, info.st_ino

    def parent(self, relative, create=False):
        chain = parts(relative)
        fd = os.open('/', FLAGS)
        try:
            for component in self.root.parts[1:]:
                next_fd = os.open(component, FLAGS, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            if self.identity is not None and self.ident(fd) != self.identity:
                raise RuntimeError('目标根身份漂移')
            for component in chain[:-1]:
                if create:
                    try: os.mkdir(component, 0o755, dir_fd=fd)
                    except FileExistsError: pass
                next_fd = os.open(component, FLAGS, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            return fd
        except BaseException:
            os.close(fd)
            raise

    def state(self, relative):
        try: fd = self.parent(relative)
        except FileNotFoundError: return None
        try:
            try: source = os.open(parts(relative)[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            except FileNotFoundError: return None
            try:
                info = os.fstat(source)
                if not stat.S_ISREG(info.st_mode): raise RuntimeError('目标不是普通文件')
                with os.fdopen(source, 'rb', closefd=False) as stream: data = stream.read()
                return (info.st_dev, info.st_ino, info.st_mode & 0o777, data)
            finally: os.close(source)
        finally: os.close(fd)

    def write(self, relative, data, expected, mode=0o644, committed=None):
        fd = self.parent(relative, True)
        name = parts(relative)[-1]
        temp = '.billing-' + str(time.time_ns()) + '-' + os.urandom(8).hex()
        try:
            # 每次写入（含回滚）重开路径并检查目录身份；不跟随替换的链接。
            probe = self.parent(relative)
            try:
                if self.ident(probe) != self.ident(fd): raise RuntimeError('目标父目录身份漂移')
            finally: os.close(probe)
            if self.state(relative) != expected: raise RuntimeError('目标存在性或内容漂移：' + relative)
            out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=fd)
            try:
                with os.fdopen(out, 'wb', closefd=False) as stream:
                    stream.write(data); stream.flush(); os.fsync(out)
                os.fchmod(out, mode)
                info = os.fstat(out)
                installed = (info.st_dev, info.st_ino, info.st_mode & 0o777, data)
            finally: os.close(out)
            probe = self.parent(relative)
            try:
                if self.ident(probe) != self.ident(fd): raise RuntimeError('写入前父目录身份漂移')
            finally: os.close(probe)
            if self.state(relative) != expected: raise RuntimeError('写入前目标漂移：' + relative)
            if expected is None:
                # 新目标以硬链接的排他创建语义提交，竞争创建不会被覆盖。
                os.link(temp, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                if committed: committed(installed)
                os.unlink(temp, dir_fd=fd)
            else:
                os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)
                if committed: committed(installed)
            os.fsync(fd)
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if (info.st_dev, info.st_ino, info.st_mode & 0o777) != installed[:3]: raise RuntimeError('提交后目标身份漂移：' + relative)
            return installed
        finally:
            try: os.unlink(temp, dir_fd=fd)
            except FileNotFoundError: pass
            os.close(fd)

    def remove(self, relative, expected):
        fd = self.parent(relative)
        try:
            if self.state(relative) != expected: raise RuntimeError('回滚目标漂移：' + relative)
            probe = self.parent(relative)
            try:
                if self.ident(probe) != self.ident(fd): raise RuntimeError('回滚父目录身份漂移')
            finally: os.close(probe)
            os.unlink(parts(relative)[-1], dir_fd=fd)
            os.fsync(fd)
        finally: os.close(fd)


class Prepared:
    def __init__(self, target, bundle):
        self.target = Tree(target)
        candidate = Tree(bundle)
        self.manifest = json.loads(candidate.state('manifest.json')[3])
        self.originals = {}
        self.contents = {}
        for relative, expected in self.manifest['sources'].items():
            state = self.target.state(relative)
            if state is None or sha(state[3]) != expected: raise RuntimeError('来源版本漂移：' + relative)
            self.originals[relative] = state
        for relative, expected in self.manifest['overlays'].items():
            state = candidate.state('overlay/' + relative)
            if state is None or sha(state[3]) != expected: raise RuntimeError('候选哈希不匹配：' + relative)
            self.contents[relative] = state[3]  # 校验过的 bytes，应用阶段绝不重读 overlay。
            if relative not in self.originals:
                if self.target.state(relative) is not None: raise RuntimeError('新增目标已存在：' + relative)
                self.originals[relative] = None

    def apply(self):
        # 先复核所有来源（包括只读锚点），再写备份或目标。
        for relative, expected in self.originals.items():
            if self.target.state(relative) != expected: raise RuntimeError('应用前目标漂移：' + relative)
        prefix = '.billing-patch-backups/' + str(time.time_ns()) + '/'
        changed = []
        try:
            for relative, data in self.contents.items():
                before = self.originals[relative]
                if before is not None: self.target.write(prefix + relative, before[3], None, before[2])
                self.target.write(relative, data, before, before[2] if before else 0o644, committed=lambda state, relative=relative: changed.append((relative, state)))
            receipt = json.dumps({'source': self.manifest['sources'], 'result': self.manifest['overlays'], 'database_migrated': False}, indent=2).encode()
            self.target.write(prefix + 'receipt.json', receipt, None)
        except BaseException as cause:
            failures = []
            for relative, applied in reversed(changed):
                try:
                    before = self.originals[relative]
                    if before is None: self.target.remove(relative, applied)
                    else: self.target.write(relative, before[3], applied, before[2])
                except BaseException as error: failures.append(relative + ': ' + str(error))
            if failures: raise RuntimeError('安全回滚拒绝漂移路径，请按备份人工核对：' + '; '.join(failures)) from cause
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True, type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    prepared = Prepared(args.target, Path(__file__).absolute().parent)
    print(f'来源与候选哈希通过，共 {len(prepared.contents)} 个文件；生产支付未激活。')
    if not args.apply:
        print('dry-run：没有写目标、执行迁移或启动服务。')
        return
    prepared.apply()
    print('候选源码已应用并保留备份；数据库迁移未执行，服务未启动，付呗未启用。')


if __name__ == '__main__':
    main()
