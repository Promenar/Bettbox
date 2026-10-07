#!/usr/bin/env python3
"""创建本机 Android 发行密钥，密码仅进入临时保护文件和登录钥匙串。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile


SERVICE = 'com.appshub.bettbox.android.release'
ACCOUNT = 'keystore-password'
ALIAS = 'bettbox-release'


def command(argv, *, data=None):
    return subprocess.run(argv, input=data, capture_output=True, timeout=90)


def reference_is_absent(keychain):
    # 系统接口无法原子核对所有权后删除，失败路径保留任何已有引用。
    try:
        current = command(['/usr/bin/security', 'find-generic-password', '-s', SERVICE, '-a', ACCOUNT, str(keychain)])
        return current.returncode == 44
    except (OSError, subprocess.SubprocessError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.execute:
        print('计划：本机保护目录中新建 PKCS12/RSA4096 密钥，密码存登录钥匙串；不覆盖已有密钥，不输出密码。')
        return
    directory = Path.home() / 'Library/Application Support/BettboxSigning'
    target = directory / 'android-release.p12'
    receipt_path = directory / 'android-release.json'
    if directory.is_symlink() or target.exists() or target.is_symlink() or receipt_path.exists():
        raise RuntimeError('签名目标已存在或为链接，拒绝覆盖')
    keychain = Path.home() / 'Library/Keychains/login.keychain-db'
    if not keychain.is_file() or keychain.is_symlink():
        raise RuntimeError('本机登录钥匙串不可用，拒绝替换为其它链')
    existing = command(['/usr/bin/security', 'find-generic-password', '-s', SERVICE, '-a', ACCOUNT, str(keychain)])
    if existing.returncode != 44:
        raise RuntimeError('钥匙串引用已有记录或查询失败，拒绝创建重复身份')
    java = command(['/usr/libexec/java_home', '-v', '21'])
    if java.returncode:
        raise RuntimeError('未找到已有 JDK21，不自动安装')
    keytool = Path(java.stdout.decode().strip()) / 'bin/keytool'
    if not keytool.is_file():
        raise RuntimeError('JDK keytool 不可用')
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    password = secrets.token_hex(32)
    # 通过 stdin 传给 security，原始密码不出现在子进程 argv 或命令回显中。
    request = f'add-generic-password -a {ACCOUNT} -s {SERVICE} -w {password} {shlex.quote(str(keychain))}\n'.encode()
    created = False
    completed = False
    try:
        stored = command(['/usr/bin/security', '-i'], data=request)
        if stored.returncode:
            raise RuntimeError('密码保存钥匙串失败，未生成密钥')
        verified = command(['/usr/bin/security', 'find-generic-password', '-s', SERVICE, '-a', ACCOUNT, '-w', str(keychain)])
        if verified.returncode or not secrets.compare_digest(verified.stdout.rstrip(b'\r\n'), password.encode()):
            raise RuntimeError('钥匙串身份写入未核实，拒绝生成密钥')
        with tempfile.TemporaryDirectory(prefix='.android-key-', dir=directory) as temporary:
            folder = Path(temporary)
            pass_file = folder / 'password'
            descriptor = os.open(pass_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                stream.write(password)
            generated = folder / 'release.p12'
            result = command([str(keytool), '-genkeypair', '-noprompt', '-storetype', 'PKCS12',
                              '-keystore', str(generated), '-alias', ALIAS, '-keyalg', 'RSA',
                              '-keysize', '4096', '-validity', '10000', '-dname', 'CN=Bettbox',
                              '-storepass:file', str(pass_file), '-keypass:file', str(pass_file)])
            if result.returncode:
                raise RuntimeError('密钥生成失败，未输出原始工具响应')
            os.chmod(generated, 0o600)
            exported = command([str(keytool), '-exportcert', '-keystore', str(generated),
                                '-alias', ALIAS, '-storepass:file', str(pass_file)])
            if exported.returncode or not exported.stdout:
                raise RuntimeError('公开证书验证失败')
            # 排他链接避免检查后出现已有密钥时被覆盖。
            os.link(generated, target)
            created = True
            receipt = {'status': 'created', 'keystore': str(target), 'alias': ALIAS,
                       'keychain_service': SERVICE, 'keychain_account': ACCOUNT, 'keychain_path': str(keychain),
                       'certificate_sha256': hashlib.sha256(exported.stdout).hexdigest(),
                       'created_at': datetime.now(timezone.utc).isoformat(), 'password_logged': False}
            descriptor = os.open(receipt_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                json.dump(receipt, stream, ensure_ascii=False, indent=2)
                stream.write('\n')
            completed = True
            print(json.dumps({'status': 'created', 'keystore': str(target),
                              'certificate_sha256': receipt['certificate_sha256']}, ensure_ascii=False))
    finally:
        if not completed:
            # 不使用存在竞态的先比较后删除，保留失败引用供人工核对。
            removed = not created and reference_is_absent(keychain)
            status = {'status': 'failed-cleaned' if removed else 'partial-requires-review',
                      'keystore_created': created, 'keychain_cleanup_verified': removed,
                      'keychain_service': SERVICE, 'keychain_account': ACCOUNT}
            status_file = directory / 'android-release-status.json'
            descriptor = os.open(status_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                json.dump(status, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError):
        raise SystemExit('Android 签名密钥创建失败；未回显秘密或工具响应，保留已有身份。')
