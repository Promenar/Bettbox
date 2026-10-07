"""Android 正式签名安全注入；导入不读取凭据，不执行工具。

证书摘要绑定主控已核实的正式身份；新身份必须经明确采用与独立审阅，
不得通过修改回执或自行替换信任锚绕过校验。调用者禁止打印或记录返回环境。
SDK build-tools 固定 36.0.0，与当前 Android 构建入口一致。
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess


# 身份常量由现有创建入口持有；导入该入口不会执行 main。
_spec = importlib.util.spec_from_file_location('_bettbox_signing_identity', Path(__file__).with_name('create_android_signing.py'))
_identity_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_identity_module)
SERVICE, ACCOUNT, ALIAS = _identity_module.SERVICE, _identity_module.ACCOUNT, _identity_module.ALIAS
CERTIFICATE_SHA256 = '6a121d74f9159b27e4b44255db8f85a9cb8d59ae052e93ba7646666d8a044a82'
BUILD_TOOLS_VERSION = '36.0.0'
_SIGNING_KEYS = ('BETTBOX_ANDROID_STORE_FILE', 'BETTBOX_ANDROID_STORE_PASSWORD',
                 'BETTBOX_ANDROID_KEY_ALIAS', 'BETTBOX_ANDROID_KEY_PASSWORD')


class SigningFailure(RuntimeError):
    """仅返回固定错误类别，禁止携带工具正文、密码或任意输入。"""


def _open_regular(path, *, private=False):
    """逐层拒绝链接；文件描述符负责读取已核实的同一个文件。"""
    path = Path(os.path.abspath(path))
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or (private and
                    (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600)):
                raise SigningFailure('签名文件类型或权限拒绝')
            return fd, info
        except BaseException:
            os.close(fd)
            raise
    finally:
        os.close(directory)


def _info_fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _fingerprint(path, *, private=False):
    fd, info = _open_regular(path, private=private)
    os.close(fd)
    return _info_fingerprint(info)


def _receipt():
    home = Path.home()
    directory = home / 'Library/Application Support/BettboxSigning'
    # 先打开整个保护目录链，末端目录必须归当前用户所有且为 0700。
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in directory.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise SigningFailure('签名保护目录权限拒绝')
    finally:
        os.close(fd)
    receipt_path = directory / 'android-release.json'
    receipt_fd, receipt_info = _open_regular(receipt_path, private=True)
    receipt_identity = _info_fingerprint(receipt_info)
    with os.fdopen(receipt_fd, 'rb') as stream:
        raw = stream.read(8193)
        if _info_fingerprint(os.fstat(stream.fileno())) != receipt_identity:
            raise SigningFailure('签名回执在读取期间变化')
    if len(raw) > 8192:
        raise SigningFailure('签名回执拒绝')
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise SigningFailure('签名回执拒绝')
            result[key] = value
        return result
    value = json.loads(raw, object_pairs_hook=unique_pairs)
    target = directory / 'android-release.p12'
    keychain = home / 'Library/Keychains/login.keychain-db'
    expected = {'status': 'created', 'keystore': str(target), 'alias': ALIAS,
                'keychain_service': SERVICE, 'keychain_account': ACCOUNT,
                'keychain_path': str(keychain), 'certificate_sha256': CERTIFICATE_SHA256,
                'password_logged': False}
    if not isinstance(value, dict) or set(value) != set(expected) | {'created_at'} or any(
            type(value.get(key)) is not type(wanted) or value.get(key) != wanted for key, wanted in expected.items()) \
            or not isinstance(value.get('created_at'), str):
        raise SigningFailure('签名公开身份不匹配')
    # 原始正文与基线来自同一个 fd；路径重开只能核对，不能重定义基线。
    if _fingerprint(receipt_path, private=True) != receipt_identity:
        raise SigningFailure('签名回执在解析期间变化')
    identities = {receipt_path: receipt_identity}
    identities.update({path: _fingerprint(path, private=True) for path in (target, keychain)})
    return target, keychain, identities


def signing_environment(base_env):
    """只向返回环境注入密码；调用者不得回显或序列化该环境。"""
    try:
        target, keychain, identities = _receipt()
        result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', SERVICE,
                                 '-a', ACCOUNT, '-w', str(keychain)],
                                env={'PATH': '/usr/bin:/bin', 'HOME': str(Path.home()), 'LANG': 'C'},
                                capture_output=True, timeout=30, check=False)
        password = result.stdout.rstrip(b'\r\n')
        # 当前创建入口生成 token_hex(32)，不接受换行、空值或任意工具输出。
        if result.returncode != 0 or not re.fullmatch(rb'[0-9a-f]{64}', password):
            raise SigningFailure('签名凭据读取失败')
        if any(_fingerprint(path, private=True) != identity for path, identity in identities.items()):
            raise SigningFailure('签名身份在读取期间变化')
        env = {key: value for key, value in base_env.items() if key not in _SIGNING_KEYS}
        env.update({'BETTBOX_ANDROID_STORE_FILE': str(target), 'BETTBOX_ANDROID_KEY_ALIAS': ALIAS,
                    'BETTBOX_ANDROID_STORE_PASSWORD': password.decode('ascii'),
                    'BETTBOX_ANDROID_KEY_PASSWORD': password.decode('ascii')})
        return env
    except Exception:
        raise SigningFailure('正式签名环境不可用') from None


def verify_signed_apk(apk, env):
    """验签无密码；返回值只包含绑定的公开证书摘要。"""
    try:
        _, _, identities = _receipt()
        sdk = env.get('ANDROID_SDK_ROOT') or env.get('ANDROID_HOME')
        if not isinstance(sdk, str) or not Path(sdk).is_absolute() or (
                env.get('ANDROID_SDK_ROOT') and env.get('ANDROID_HOME') and
                env['ANDROID_SDK_ROOT'] != env['ANDROID_HOME']):
            raise SigningFailure('验签 SDK 入口拒绝')
        tool = Path(sdk) / 'build-tools' / BUILD_TOOLS_VERSION / 'apksigner'
        tool_fd, info = _open_regular(tool)
        os.close(tool_fd)
        if info.st_mode & 0o022 or not info.st_mode & 0o111:
            raise SigningFailure('验签工具权限拒绝')
        apk = Path(os.path.abspath(apk))
        before = _fingerprint(apk)
        # 验签只继承工具链所需字段，排除签名密码和任意 JVM 注入参数。
        allowed = ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')
        clean_env = {key: value for key, value in env.items() if key in allowed}
        result = subprocess.run([str(tool), 'verify', '--print-certs', str(apk)],
                                env=clean_env, capture_output=True, timeout=90, check=False)
        if result.returncode != 0 or len(result.stdout) > 131072:
            raise SigningFailure('APK 验签失败')
        output = result.stdout.decode('utf-8', errors='strict')
        certificates = re.findall(r'^Signer #([0-9]+) certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$', output, re.M)
        # 不接受调试身份、多个签名者或缺失的签名证据。
        if len(certificates) != 1 or certificates[0][0] != '1' or certificates[0][1].lower() != CERTIFICATE_SHA256:
            raise SigningFailure('APK 签名身份不匹配')
        if _fingerprint(apk) != before or any(_fingerprint(path, private=True) != identity for path, identity in identities.items()):
            raise SigningFailure('验签期间输入变化')
        return {'verified': True, 'certificate_sha256': CERTIFICATE_SHA256, 'signers': 1}
    except Exception:
        raise SigningFailure('正式 APK 验签失败') from None
