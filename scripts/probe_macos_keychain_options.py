#!/usr/bin/env python3
"""本机合成键诊断；签名工具原文及Keychain值不进入输出。"""
import json
from pathlib import Path
import subprocess
import uuid

import seal_macos_candidate as seal

ROOT = Path(__file__).resolve().parents[1]
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}


def main():
    output = ROOT / ".test/macos-keychain-options" / str(uuid.uuid4())
    seal.identity.public_parents(ROOT, output.parent)
    output.mkdir(mode=0o700)
    account = str(uuid.uuid4())
    # 仅为失败后定位同次合成条目；不存业务凭据或Keychain返回值。
    (output / "case.json").write_text(json.dumps({"synthetic_account": account}))
    binary = output / "Probe"
    fingerprint, _, _ = seal.development_identity()
    for argv in (["/usr/bin/xcrun", "swiftc", str(ROOT / "scripts/probe_macos_keychain_options.swift"), "-o", str(binary)],
                 ["/usr/bin/codesign", "--force", "--sign", fingerprint,
                  "--identifier", "com.appshub.bettbox.synthetic-keychain-probe", str(binary)],
                 ["/usr/bin/codesign", "--verify", "--strict", str(binary)]):
        result = subprocess.run(argv, env=ENV, capture_output=True, timeout=120)
        if result.returncode:
            print(json.dumps({"tool_stage_passed": False}))
            return 1
    try:
        result = subprocess.run([str(binary), account], env=ENV, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        print(json.dumps({"probe_completed": False, "synthetic_cleanup_pending": True}))
        return 1
    if result.returncode or len(result.stdout) > 4096:
        print(json.dumps({"probe_completed": False, "synthetic_cleanup_pending": True}))
        return 1
    try:
        report = json.loads(result.stdout)
    except ValueError:
        print(json.dumps({"probe_completed": False, "synthetic_cleanup_pending": True}))
        return 1
    expected = {"new_key_absent", "sync_query_status", "first_write_status", "first_read_matches",
                "overwrite_status", "overwrite_read_matches", "sync_delete_status", "local_delete_status",
                "absent_after_delete", "repeat_delete_status", "plugin_delete_status",
                "plugin_repeat_delete_status", "real_credentials_accessed", "scope"}
    if not isinstance(report, dict) or set(report) != expected:
        print(json.dumps({"probe_completed": False, "synthetic_cleanup_pending": True}))
        return 1
    booleans = {"new_key_absent", "first_read_matches", "overwrite_read_matches",
                "absent_after_delete", "real_credentials_accessed"}
    if (any(type(report[k]) is not bool for k in booleans)
            or any(type(report[k]) is not int for k in expected - booleans - {"scope"})
            or report["scope"] != "独立合成键的原生查询行为；不代表完整Flutter插件或App验收"):
        print(json.dumps({"probe_completed": False, "synthetic_cleanup_pending": True}))
        return 1
    (output / "receipt.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["absent_after_delete"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print("MACOS_KEYCHAIN_PROBE_FAILED")
        raise SystemExit(1)
