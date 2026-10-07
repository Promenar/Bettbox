#!/usr/bin/env python3
"""固定本机macOS候选的嵌套开发签名；保留未签宿主作为构建证据。"""
import hashlib
import argparse
import os
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

import macos_core_identity as identity

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("build/macos/Build/Products/Release/Bettbox.app")
DESTINATION = Path("build/macos-local-candidate/Bettbox.app")
PROBE_DESTINATION = Path("build/macos-flutter-supervisor/Bettbox.app")
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def tool(argv):
    result = subprocess.run(argv, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=60, check=False)
    if result.returncode:
        raise RuntimeError("候选签名工具失败")
    return result


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


def seal(root=ROOT, destination_relative=DESTINATION):
    if destination_relative not in (DESTINATION, PROBE_DESTINATION):
        raise RuntimeError("候选目标目录不符")
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
            tool(["/usr/bin/codesign", "--force", "--sign", "-", str(path)])
    for framework in frameworks:
        if framework.is_symlink(): raise RuntimeError("framework bundle不允许链接")
        tool(["/usr/bin/codesign", "--force", "--sign", "-", str(framework)])
        tool(["/usr/bin/codesign", "--verify", "--strict", str(framework)])
    info = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.appshub.bettbox" or info.get("CFBundleExecutable") != "Bettbox":
        raise RuntimeError("宿主固定bundle身份不符")
    host_argv = ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.appshub.bettbox"]
    # 探针不使用账户或钥匙串；ad hoc宿主不能携带受限钥匙串权利。
    if destination_relative != PROBE_DESTINATION:
        host_argv += ["--entitlements", str(root / "macos/Runner/Release.entitlements")]
    tool(host_argv + [str(destination)])
    tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)])
    host_signature = tool(["/usr/bin/codesign", "-d", "--verbose=4", str(destination)]).stderr.decode("utf-8", errors="strict")
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
    report = {"schema": 1, "passed": True, "signingmode": "adhoc", "notarized": False,
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
    arguments = parser.parse_args()
    try:
        seal(destination_relative=PROBE_DESTINATION if arguments.probe else DESTINATION)
        print("MACOS_CANDIDATE_SEAL_PASS")
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
        print("MACOS_CANDIDATE_SEAL_FAIL"); raise SystemExit(1)
