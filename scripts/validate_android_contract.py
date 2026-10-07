#!/usr/bin/env python3
"""验证 Android 项目扩展及统一 PDEC；不执行构建。"""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def validate_android(root: Path, contract: dict) -> dict:
    """统一工具暂未枚举 Android，项目扩展保留真实产物平台。"""
    operation = contract.get("platform_extensions", {}).get("android", {})
    expected = {
        "executor": "local-mac",
        "target_os": "android",
        "target_arch": "arm64",
        "cwd": ".",
        "argv": ["python3", "scripts/build_android.py", "--execute"],
        "artifacts": ["build/app/outputs/flutter-apk/app-debug.apk"],
    }
    for key, value in expected.items():
        if operation.get(key) != value:
            raise ValueError(f"Android 扩展字段不符合已批准范围：{key}")
    host = contract.get("targets", {}).get("local-mac", {})
    if host != {"os": "macos", "arch": "arm64"}:
        raise ValueError("Android 扩展仅授权本机 Apple Silicon 执行")
    timeout = operation.get("timeout_seconds")
    if type(timeout) is not int or not 0 < timeout <= 2700:
        raise ValueError("Android 超时配置无效")
    source = root / "scripts/build_android.py"
    if not source.is_file() or source.is_symlink():
        raise ValueError("Android 构建入口不存在或为符号链接")
    return operation


def validate_android_release(root: Path, contract: dict) -> dict:
    """正式签名使用独立扩展，缺失不影响 debug 校验。"""
    operation = contract.get("platform_extensions", {}).get("android_release", {})
    expected = {
        "executor": "local-mac", "target_os": "android", "target_arch": "arm64",
        "cwd": ".", "argv": ["python3", "scripts/build_android.py", "--execute", "--release"],
        "artifacts": ["build/app/outputs/flutter-apk/app-release.apk"],
        "timeout_seconds": 2700,
    }
    for key, value in expected.items():
        if operation.get(key) != value or (key == "timeout_seconds" and type(operation.get(key)) is not int):
            raise ValueError(f"Android release 扩展字段不符合已批准范围：{key}")
    # 共用主机和入口边界，不依赖是否配置 debug 扩展。
    validation_contract = dict(contract)
    validation_contract["platform_extensions"] = {"android": {**operation,
        "argv": ["python3", "scripts/build_android.py", "--execute"],
        "artifacts": ["build/app/outputs/flutter-apk/app-debug.apk"]}}
    validate_android(root, validation_contract)
    return operation


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework-validator", required=True,
                        help="已安装 remote-development 的 pdec.py 路径")
    parser.add_argument("--release", action="store_true", help="验证正式签名 Android 扩展")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        result = subprocess.run(
            [sys.executable, args.framework_validator, "validate", "--root", str(root)],
            check=True, capture_output=True, text=True,
        )
        framework = json.loads(result.stdout)
        if framework.get("execution_ready") is not True:
            raise ValueError("统一 PDEC 未就绪")
        contract = json.loads((root / ".pdec/contract.yaml").read_text())
        operation = validate_android_release(root, contract) if args.release else validate_android(root, contract)
        print(json.dumps({"execution_ready": True, "framework": framework,
                          ("release_operation" if args.release else "android_operation"): operation}, ensure_ascii=False))
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Android 扩展校验失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
