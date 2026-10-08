#!/usr/bin/env python3
"""固定本机macOS候选的嵌套开发签名；保留未签宿主作为构建证据。"""
import hashlib
import argparse
import os
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

import macos_core_identity as identity

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("build/macos/Build/Products/Release/Bettbox.app")
DESTINATION = Path("build/macos-local-candidate/Bettbox.app")
PROBE_DESTINATION = Path("build/macos-flutter-supervisor/Bettbox.app")
LOCAL_DEVELOPMENT_DESTINATION = Path("build/macos-local-development/Bettbox.app")
LOCAL_BUILD_MANIFEST = Path("build/desktop-validation/macos-arm64.json")
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def tool(argv, input_data=None):
    try:
        options = {"env": ENV, "stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
                   "timeout": 60, "check": False}
        if input_data is not None:
            options["input"] = input_data
        result = subprocess.run(argv, **options)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("候选签名工具失败") from None
    if result.returncode:
        raise RuntimeError("候选签名工具失败")
    return result


def captured_text(raw, failure):
    if not isinstance(raw, bytes) or len(raw) > 65536:
        raise RuntimeError(failure)
    try:
        return raw.decode("utf-8", errors="strict")
    except UnicodeError:
        raise RuntimeError(failure) from None


def development_identity():
    # 身份名称与工具原文仅在本地解析，不进入清单或错误信息。
    result = tool(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    text = captured_text(result.stdout, "开发签名身份格式不符")
    entries = []
    total = None
    for line in text.splitlines():
        if not line.strip():
            continue
        summary = re.fullmatch(r"\s*(\d+) valid identities found\s*", line)
        if summary:
            if total is not None:
                raise RuntimeError("开发签名身份格式不符")
            total = int(summary.group(1))
            continue
        entry = re.fullmatch(r'\s*(\d+)\) ([0-9A-Fa-f]{40}) "([^"\r\n]+)"\s*', line)
        if entry is None or total is not None or int(entry.group(1)) != len(entries) + 1:
            raise RuntimeError("开发签名身份格式不符")
        entries.append((entry.group(2).upper(), entry.group(3)))
    if total is None or total != len(entries) or len({item[0] for item in entries}) != len(entries):
        raise RuntimeError("开发签名身份格式不符")
    candidates = []
    for fingerprint, name in entries:
        if not name.startswith("Apple Development:"):
            continue
        match = re.fullmatch(r"Apple Development: [^\r\n]+ \(([A-Z0-9]{10})\)", name)
        if match is None:
            raise RuntimeError("开发签名身份格式不符")
        candidates.append((fingerprint, name))
    if len(candidates) != 1:
        raise RuntimeError("开发签名身份数量不符")
    fingerprint, name = candidates[0]
    return fingerprint, development_team(fingerprint), name


def development_team(fingerprint):
    # 证书CN后缀不是Team；以选中SHA1匹配公开证书，再读取唯一Subject OU。
    raw = tool(["/usr/bin/security", "find-certificate", "-a", "-p", "-c", "Apple Development"]).stdout
    failure = "开发签名证书Team不符"
    if not isinstance(raw, bytes) or len(raw) > 1048576:
        raise RuntimeError(failure)
    pattern = rb"-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----"
    certificates = re.findall(pattern, raw)
    if not certificates or len(certificates) > 32 or re.sub(pattern, b"", raw).strip():
        raise RuntimeError(failure)
    teams = []
    for certificate in certificates:
        result = tool(["/usr/bin/openssl", "x509", "-noout", "-fingerprint", "-sha1",
                       "-subject", "-nameopt", "RFC2253"], input_data=certificate + b"\n")
        lines = captured_text(result.stdout, failure).splitlines()
        hashes = [line for line in lines if re.fullmatch(r"SHA1 Fingerprint=(?:[0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}", line, re.IGNORECASE)]
        subjects = [line for line in lines if line.startswith("subject=")]
        if len(lines) != 2 or len(hashes) != 1 or len(subjects) != 1:
            raise RuntimeError(failure)
        actual = hashes[0].split("=", 1)[1].replace(":", "").upper()
        if actual != fingerprint:
            continue
        subject = subjects[0][len("subject="):].strip()
        fields = []
        current = ""
        escaped = False
        for character in subject:
            if not escaped and character in ",+":
                fields.append(current)
                current = ""
            else:
                current += character
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
        fields.append(current)
        units = [field[3:] for field in fields if field.startswith("OU=")]
        if len(units) != 1 or re.fullmatch(r"[A-Z0-9]{10}", units[0]) is None:
            raise RuntimeError(failure)
        teams.append(units[0])
    if len(teams) != 1:
        raise RuntimeError(failure)
    return teams[0]


def development_host(signature, selected):
    # 开发宿主独立核验，不借用仅允许ad hoc的固定Core解析器。
    text = captured_text(signature, "宿主开发签名身份不符")
    lines = text.splitlines()
    def values(prefix):
        return [line[len(prefix):] for line in lines if line.startswith(prefix)]
    fingerprints = values("CDHash=")
    authorities = values("Authority=")
    if (values("Identifier=") != ["com.appshub.bettbox"] or
            len(fingerprints) != 1 or re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprints[0]) is None or
            values("TeamIdentifier=") != [selected[1]] or
            values("Signature=") or
            authorities != [selected[2], "Apple Worldwide Developer Relations Certification Authority", "Apple Root CA"]):
        raise RuntimeError("宿主开发签名身份不符")
    return {"cdhash": fingerprints[0].lower(), "team": selected[1]}


def checked_tree(app):
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError("候选bundle路径无效")
    for path in app.rglob("*"):
        if path.is_symlink():
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(app.resolve()):
                raise RuntimeError("候选bundle存在越界链接")
        elif not path.is_dir() and not path.is_file():
            raise RuntimeError("候选bundle存在特殊文件")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish_report(parent, report):
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptor = None
    created = False
    try:
        descriptor = os.open("seal.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        created = True
        data = (json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
        offset = 0
        while offset < len(data):
            amount = os.write(descriptor, data[offset:])
            if amount <= 0: raise RuntimeError("候选清单写入无进展")
            offset += amount
        os.fsync(descriptor)
        os.fsync(directory)
    except Exception:
        if created: os.unlink("seal.json", dir_fd=directory)
        raise
    finally:
        if descriptor is not None: os.close(descriptor)
        os.close(directory)


def artifact(app, name, identifier):
    # Core/helper固定身份和manifest保持Xcode复制的签后字节，不再签名。
    binary = app / "Contents/MacOS" / name
    manifest = app / "Contents/Resources" / (name + "Identity.json")
    if binary.is_symlink() or manifest.is_symlink():
        raise RuntimeError("固定产物不允许链接")
    raw = manifest.read_bytes()
    if len(raw) > 4096:
        raise RuntimeError("固定身份清单过大")
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result: raise RuntimeError("固定身份字段重复")
            result[key] = value
        return result
    fields = json.loads(raw, object_pairs_hook=pairs)
    if not isinstance(fields, dict) or fields.get("identifier") != identifier:
        raise RuntimeError("固定产物身份不符")
    # 复用严格五字段验证，helper只在解析副本中替换已核对的固定ID。
    normalized = dict(fields); normalized["identifier"] = identity.CORE_IDENTIFIER
    identity.validate_core_identity(normalized)
    if raw != (json.dumps(fields, sort_keys=True) + "\n").encode() or fields["sha256"] != digest(binary):
        raise RuntimeError("固定产物摘要或canonical清单不符")
    tool(["/usr/bin/codesign", "--verify", "--strict", str(binary)])
    signature = tool(["/usr/bin/codesign", "-d", "--verbose=4", str(binary)]).stderr.decode("utf-8", errors="strict")
    if [line for line in signature.splitlines() if line.startswith("Identifier=")] != ["Identifier=" + identifier]:
        raise RuntimeError("固定产物签名ID不符")
    signature = signature.replace("Identifier=" + identifier + "\n", "Identifier=" + identity.CORE_IDENTIFIER + "\n")
    actual = identity.parse_core_signature(signature); actual["sha256"] = digest(binary)
    if actual != normalized: raise RuntimeError("固定产物实际签名不符")
    return fields


def require_supported_entitlement_profile(root, destination_relative):
    if destination_relative == PROBE_DESTINATION:
        return {}
    local = destination_relative == LOCAL_DEVELOPMENT_DESTINATION
    path = root / ("macos/Runner/LocalDevelopment.entitlements" if local else "macos/Runner/Release.entitlements")
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 16384:
        raise RuntimeError("候选权利配置无效")
    for parent in path.parents:
        if parent == root:
            break
        if parent.is_symlink():
            raise RuntimeError("候选权利配置无效")
    try:
        entitlements = plistlib.loads(path.read_bytes())
    except (ValueError, TypeError, plistlib.InvalidFileException):
        raise RuntimeError("候选权利配置无效") from None
    if not isinstance(entitlements, dict):
        raise RuntimeError("候选权利配置无效")
    # 此封装器没有profile信任与受限权利授权校验，空访问组数组也不能放行。
    if entitlements:
        if local:
            raise RuntimeError("本机开发权利必须为空")
        raise RuntimeError("完整候选需要经过provisioning profile准入验证")
    # 没有profile授权校验时仅支持无权利宿主；返回快照用于验签后核对。
    return entitlements


def local_build_admission(root, source):
    try:
        return _local_build_admission(root, source)
    except OSError:
        raise RuntimeError("本机开发构建来源未验证") from None


def local_framework_entry(app):
    # 固定加载入口链路，禁止内部其它版本绕过已核验A版本摘要。
    framework = app / "Contents/Frameworks/App.framework"
    for relative, target in (("App", "Versions/Current/App"), ("Versions/Current", "A")):
        path = framework / relative
        if not path.is_symlink() or os.readlink(path) != target:
            raise RuntimeError("本机开发framework加载入口不符")
    if ((framework / "App").resolve(strict=True) != (framework / "Versions/A/App").resolve(strict=True) or
            (framework / "Versions/Current").resolve(strict=True) != (framework / "Versions/A").resolve(strict=True)):
        raise RuntimeError("本机开发framework加载入口不符")


def _local_build_admission(root, source):
    # 完整构建清单只证明本机开发来源，不授予profile或发行资格。
    failure = "本机开发构建来源未验证"
    local_framework_entry(source)
    descriptor, directory, before = identity.open_public_file(root, LOCAL_BUILD_MANIFEST)
    try:
        if before.st_size > 16777216:
            raise RuntimeError(failure)
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            raw = stream.read(16777217)
        identity.check_public_binding(root, LOCAL_BUILD_MANIFEST, descriptor, directory, before)
    finally:
        os.close(descriptor); os.close(directory)
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RuntimeError(failure)
            result[key] = value
        return result
    try:
        fields = json.loads(raw, object_pairs_hook=pairs)
    except (ValueError, TypeError, UnicodeError):
        raise RuntimeError(failure) from None
    required = {"target": "macos-arm64", "build_channel": "local-macos-development",
                "local_development_keychain": True, "commands_succeeded": True,
                "source_unchanged": True, "locks_unchanged": True,
                "host_signing_mode": "unsigned", "bundle_path": SOURCE.as_posix()}
    if not isinstance(fields, dict) or any(
            type(fields.get(key)) is not type(value) or fields.get(key) != value
            for key, value in required.items()):
        raise RuntimeError(failure)
    records = fields.get("bundle_files")
    if not isinstance(records, list) or not records:
        raise RuntimeError(failure)
    evidence = {}
    for record in records:
        if (not isinstance(record, dict) or not isinstance(record.get("path"), str) or
                type(record.get("size")) is not int or record["size"] < 0 or
                not isinstance(record.get("sha256"), str) or
                re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is None):
            raise RuntimeError(failure)
        relative = Path(record["path"])
        if (relative.is_absolute() or ".." in relative.parts or
                relative.as_posix() != record["path"] or not relative.is_relative_to(SOURCE) or
                record["path"] in evidence):
            raise RuntimeError(failure)
        evidence[record["path"]] = record
    if any(source.rglob("embedded.provisionprofile")):
        raise RuntimeError("本机开发候选不允许未验证profile")
    verified = {}
    # Flutter框架公开App为内部链接；只读取固定版本目录中的实际普通文件。
    for suffix in ("Contents/MacOS/Bettbox", "Contents/Frameworks/App.framework/Versions/A/App"):
        relative = SOURCE / suffix
        expected = evidence.get(relative.as_posix())
        if expected is None:
            raise RuntimeError(failure)
        descriptor, directory, before = identity.open_public_file(root, relative)
        try:
            actual = identity.hash_bound_file(descriptor)
            after = identity.check_public_binding(root, relative, descriptor, directory, before)
            if actual != expected["sha256"] or after.st_size != expected["size"]:
                raise RuntimeError(failure)
            verified[suffix] = actual
        finally:
            os.close(descriptor); os.close(directory)
    return verified


def verified_host_entitlements(app, expected):
    raw = tool(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)]).stdout
    if not isinstance(raw, bytes) or len(raw) > 16384:
        raise RuntimeError("宿主实际权利不符")
    try:
        actual = plistlib.loads(raw) if raw else {}
    except (ValueError, TypeError, plistlib.InvalidFileException):
        raise RuntimeError("宿主实际权利不符") from None
    if not isinstance(actual, dict) or actual != expected:
        raise RuntimeError("宿主实际权利不符")


def seal(root=ROOT, destination_relative=DESTINATION, signing_mode="adhoc", local_development=False):
    if signing_mode not in ("adhoc", "apple-development"):
        raise RuntimeError("候选签名模式不符")
    if type(local_development) is not bool:
        raise RuntimeError("候选开发模式不符")
    if local_development:
        if signing_mode != "apple-development" or destination_relative != DESTINATION:
            raise RuntimeError("本机开发候选目标或签名模式不符")
        destination_relative = LOCAL_DEVELOPMENT_DESTINATION
    if destination_relative not in (DESTINATION, PROBE_DESTINATION) and not local_development:
        raise RuntimeError("候选目标目录不符")
    source = root / SOURCE; destination = root / destination_relative
    local_evidence = None
    if local_development:
        checked_tree(source)
        local_evidence = local_build_admission(root, source)
        require_supported_entitlement_profile(root, destination_relative)
    selected = development_identity() if signing_mode == "apple-development" else None
    signing_identity = selected[0] if selected is not None else "-"
    checked_tree(source)
    expected_entitlements = require_supported_entitlement_profile(root, destination_relative)
    # build父目录必须是项目内实际目录；不覆盖既有候选。
    identity.public_parents(root, source.parent)
    if destination.parent.exists(): identity.public_parents(root, destination.parent)
    else:
        identity.public_parents(root, destination.parent.parent)
        destination.parent.mkdir(mode=0o700)
    if destination.exists() or destination.is_symlink(): raise RuntimeError("候选目录已存在")
    marker = destination.parent / "seal.json"
    if marker.exists() or marker.is_symlink(): raise RuntimeError("候选清单已存在")
    baseline = {name: artifact(source, name, identifier) for name, identifier in (
        ("BettboxCore", "com.appshub.bettbox.core"),
        ("BettboxCoreSupervisor", "com.appshub.bettbox.core.supervisor"))}
    source_host = digest(source / "Contents/MacOS/Bettbox")
    shutil.copytree(source, destination, symlinks=True)
    checked_tree(destination)
    if local_development:
        local_framework_entry(destination)
    if local_development and any(digest(destination / suffix) != expected
                                 for suffix, expected in local_evidence.items()):
        raise RuntimeError("本机开发候选复制字节不符")
    framework_root = destination / "Contents/Frameworks"
    frameworks = sorted(framework_root.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True)
    # 先签叶级Mach-O，再签其bundle；不使用签名--deep推测层次。
    for path in sorted(framework_root.rglob("*")):
        if path.is_symlink() or not path.is_file(): continue
        with path.open("rb") as file: magic = file.read(4)
        if magic in MAGIC:
            tool(["/usr/bin/codesign", "--force", "--sign", signing_identity, str(path)])
    for framework in frameworks:
        if framework.is_symlink(): raise RuntimeError("framework bundle不允许链接")
        tool(["/usr/bin/codesign", "--force", "--sign", signing_identity, str(framework)])
        tool(["/usr/bin/codesign", "--verify", "--strict", str(framework)])
    info = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.appshub.bettbox" or info.get("CFBundleExecutable") != "Bettbox":
        raise RuntimeError("宿主固定bundle身份不符")
    host_argv = ["/usr/bin/codesign", "--force", "--sign", signing_identity, "--identifier", "com.appshub.bettbox"]
    # 探针不使用账户或钥匙串；ad hoc宿主不能携带受限钥匙串权利。
    if destination_relative != PROBE_DESTINATION:
        entitlement = "LocalDevelopment.entitlements" if local_development else "Release.entitlements"
        host_argv += ["--entitlements", str(root / "macos/Runner" / entitlement)]
    tool(host_argv + [str(destination)])
    tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)])
    verified_host_entitlements(destination, expected_entitlements)
    if local_development:
        local_framework_entry(destination)
    host_raw = tool(["/usr/bin/codesign", "-d", "--verbose=4", str(destination)]).stderr
    if selected is not None:
        host_identity = development_host(host_raw, selected)
    else:
        host_signature = host_raw.decode("utf-8", errors="strict")
        if [line for line in host_signature.splitlines() if line.startswith("Identifier=")] != ["Identifier=com.appshub.bettbox"]:
            raise RuntimeError("宿主实际签名ID不符")
        host_identity = identity.parse_core_signature(host_signature.replace(
            "Identifier=com.appshub.bettbox\n", "Identifier=" + identity.CORE_IDENTIFIER + "\n"))
    after = {name: artifact(destination, name, identifier) for name, identifier in (
        ("BettboxCore", "com.appshub.bettbox.core"),
        ("BettboxCoreSupervisor", "com.appshub.bettbox.core.supervisor"))}
    source_after = {name: artifact(source, name, identifier) for name, identifier in (
        ("BettboxCore", "com.appshub.bettbox.core"),
        ("BettboxCoreSupervisor", "com.appshub.bettbox.core.supervisor"))}
    if after != baseline or source_after != baseline or digest(source / "Contents/MacOS/Bettbox") != source_host:
        raise RuntimeError("签名期间固定产物或原宿主漂移")
    if local_development and (local_build_admission(root, source) != local_evidence or
                              require_supported_entitlement_profile(root, destination_relative) != expected_entitlements):
        raise RuntimeError("本机开发构建来源或权利漂移")
    report = {"schema": 1, "passed": True, "signingmode": signing_mode, "notarized": False,
              "launch_validated": False,
              "source": SOURCE.as_posix(), "destination": destination_relative.as_posix(),
              "nested_frameworks": len(frameworks), "artifacts": after,
              "host_sha256": digest(destination / "Contents/MacOS/Bettbox"),
              "host_cdhash": host_identity["cdhash"],
              "entitlement_profile": "probe-none" if destination_relative == PROBE_DESTINATION else "release",
              "scope": "完整bundle开发签名；不证明应用会话、系统代理或发行资格"}
    if local_development:
        report.update(entitlement_profile="local-development", build_channel="local-macos-development",
                      distribution="non-distribution", local_development_keychain=True,
                      source_build_manifest=LOCAL_BUILD_MANIFEST.as_posix())
    publish_report(destination.parent, report)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="固定本机macOS候选开发签名")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--probe", action="store_true")
    modes.add_argument("--local-development", action="store_true")
    parser.add_argument("--signing-mode", choices=("adhoc", "apple-development"), default="adhoc")
    arguments = parser.parse_args()
    try:
        seal(destination_relative=PROBE_DESTINATION if arguments.probe else DESTINATION,
             signing_mode=arguments.signing_mode, local_development=arguments.local_development)
        print("MACOS_CANDIDATE_SEAL_PASS")
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
        print("MACOS_CANDIDATE_SEAL_FAIL"); raise SystemExit(1)
