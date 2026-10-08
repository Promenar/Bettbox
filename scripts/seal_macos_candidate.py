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


def seal(root=ROOT, destination_relative=DESTINATION, signing_mode="adhoc"):
    if signing_mode not in ("adhoc", "apple-development"):
        raise RuntimeError("候选签名模式不符")
    if destination_relative not in (DESTINATION, PROBE_DESTINATION):
        raise RuntimeError("候选目标目录不符")
    selected = development_identity() if signing_mode == "apple-development" else None
    signing_identity = selected[0] if selected is not None else "-"
    source = root / SOURCE; destination = root / destination_relative
    checked_tree(source)
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
        host_argv += ["--entitlements", str(root / "macos/Runner/Release.entitlements")]
    tool(host_argv + [str(destination)])
    tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)])
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
    report = {"schema": 1, "passed": True, "signingmode": signing_mode, "notarized": False,
              "source": SOURCE.as_posix(), "destination": destination_relative.as_posix(),
              "nested_frameworks": len(frameworks), "artifacts": after,
              "host_sha256": digest(destination / "Contents/MacOS/Bettbox"),
              "host_cdhash": host_identity["cdhash"],
              "entitlement_profile": "probe-none" if destination_relative == PROBE_DESTINATION else "release",
              "scope": "完整bundle开发签名；不证明应用会话、系统代理或发行资格"}
    publish_report(destination.parent, report)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="固定本机macOS候选开发签名")
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--signing-mode", choices=("adhoc", "apple-development"), default="adhoc")
    arguments = parser.parse_args()
    try:
        seal(destination_relative=PROBE_DESTINATION if arguments.probe else DESTINATION,
             signing_mode=arguments.signing_mode)
        print("MACOS_CANDIDATE_SEAL_PASS")
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
        print("MACOS_CANDIDATE_SEAL_FAIL"); raise SystemExit(1)
