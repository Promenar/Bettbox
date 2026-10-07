#!/usr/bin/env python3
"""生成内嵌 Mihomo 核心 XCFramework；不安装工具、不签名、不启动系统 VPN。"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def capture(command: list[str]) -> str:
    return subprocess.check_output(command, text=True).strip()


def source_hashes(root: Path) -> dict[str, str]:
    sources = {path for path in (root / "core").rglob("*") if path.suffix in {".go", ".c", ".h", ".s", ".S"}}
    sources |= {root / "core" / "go.mod", root / "core" / "go.sum", root / "core" / "Clash.Meta" / "go.mod", root / "core" / "Clash.Meta" / "go.sum", Path(__file__).resolve()}
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(sources) if path.is_file()}


def build(args: argparse.Namespace) -> None:
    if sys.platform != "darwin":
        raise RuntimeError("iOS 制品必须在已配置 Xcode 的 macOS 执行")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", args.minimum_ios):
        raise ValueError("最低 iOS 版本必须是数字版本号")
    root = Path(__file__).resolve().parents[1]
    output = Path(args.output).resolve() if args.output else root / "build" / "ios-packet-bridge"
    # 不覆盖已有制品，调用方可选择新的输出目录保留验证证据。
    if output.exists():
        raise FileExistsError(f"输出目录已存在：{output}")
    output.mkdir(parents=True)
    initial_hashes = source_hashes(root)
    initial_sha = capture(["git", "-C", str(root), "rev-parse", "HEAD"])
    status_command = ["git", "-C", str(root), "status", "--short", "--", "core", "scripts/build_ios_core.py"]
    initial_status = capture(status_command)
    env = os.environ.copy()
    env.update({"CGO_ENABLED": "1", "GOOS": "ios", "GOARCH": "arm64", "GOWORK": "off"})
    receipts: list[dict[str, str]] = []
    framework_command = ["xcodebuild", "-create-xcframework"]
    for name, sdk, suffix in [("device-arm64", "iphoneos", ""), ("simulator-arm64", "iphonesimulator", "-simulator")]:
        sdk_path = capture(["xcrun", "--sdk", sdk, "--show-sdk-path"])
        clang = capture(["xcrun", "--sdk", sdk, "--find", "clang"])
        destination = output / name
        destination.mkdir()
        library = destination / "libBettboxCore.a"
        target = f"arm64-apple-ios{args.minimum_ios}{suffix}"
        flags = f"-target {target} -isysroot '{sdk_path}'"
        variant_env = env | {"CC": clang, "CGO_CFLAGS": flags, "CGO_LDFLAGS": flags}
        subprocess.run(
            [args.go, "build", "-mod=readonly", "-trimpath", "-tags=with_gvisor", "-buildmode=c-archive", "-o", str(library), "."],
            cwd=root / "core", env=variant_env, check=True,
        )
        generated_header = library.with_suffix(".h")
        if not generated_header.is_file():
            raise RuntimeError("Go 未生成 C ABI 头文件")
        headers = destination / "headers"
        headers.mkdir()
        shutil.copyfile(generated_header, headers / "BettboxCore.h")
        (headers / "module.modulemap").write_text('''module BettboxCore {
  header "BettboxCore.h"
  export *
}
''', encoding="utf-8")
        c_probe = destination / "import-probe.m"
        c_probe.write_text("@import BettboxCore;\n", encoding="utf-8")
        subprocess.run([clang, "-target", target, "-isysroot", sdk_path, "-fmodules", "-fsyntax-only", "-I", str(headers), str(c_probe)], check=True)
        swift_probe = destination / "import-probe.swift"
        swift_probe.write_text("import BettboxCore\n", encoding="utf-8")
        swift = capture(["xcrun", "--sdk", sdk, "--find", "swiftc"])
        subprocess.run([swift, "-typecheck", "-target", target, "-sdk", sdk_path, "-I", str(headers), str(swift_probe)], check=True)
        framework_command += ["-library", str(library), "-headers", str(headers)]
        receipts.append({"variant": name, "sdk": sdk, "sdk_path": sdk_path, "target": target})
    framework_command += ["-output", str(output / "BettboxCore.xcframework")]
    subprocess.run(framework_command, cwd=root, check=True)
    if source_hashes(root) != initial_hashes or capture(status_command) != initial_status or capture(["git", "-C", str(root), "rev-parse", "HEAD"]) != initial_sha:
        raise RuntimeError("构建期间源码或模块锁文件发生变化，制品不能作为同版本验收证据")
    # 只记录公开工具链信息，避免序列化环境变量或签名资料。
    receipt = {
        "scope": "embedded-mihomo-packet-flow-core",
        "vpn_ready": False,
        "go_version": capture([args.go, "version"]),
        "xcode_version": capture(["xcodebuild", "-version"]),
        "source_sha": initial_sha,
        "source_worktree_status": initial_status,
        "source_hashes": initial_hashes,
        "artifact_hashes": {str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.rglob("*")) if path.is_file() and (path.suffix in {".a", ".h", ".modulemap"} or path.name == "module.modulemap")},
        "variants": receipts,
    }
    (output / "build-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"内嵌 Mihomo 核心制品：{output / 'BettboxCore.xcframework'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="新的输出目录，已有目录不覆盖")
    parser.add_argument("--minimum-ios", default="15.0", help="最低 iOS 版本")
    parser.add_argument("--go", default="go", help="已安装 Go 可执行文件")
    args = parser.parse_args()
    try:
        build(args)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"构建失败：{error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
