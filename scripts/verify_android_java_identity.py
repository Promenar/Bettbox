"""以无网络、无秘密、自然退出的自有 Java 进程验证内核身份接口。"""
from __future__ import annotations
import json
import subprocess
import shutil
import tempfile
import time
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts import build_android as android

ROOT = Path(__file__).resolve().parents[1]
def main() -> int:
    facts = {"verified": False, "natural_exit": False, "signals_sent": False}
    try:
        receipt = json.loads((ROOT / ".test/android-build/receipt.json").read_text())
        tool = receipt["toolchain"]
        env = android.build_environment()
        flutter = shutil.which("flutter", path=env.get("PATH"))
        if not flutter:
            raise RuntimeError("缺少Flutter入口")
        selected, _ = android.selected_java(Path(flutter), ROOT, env, time.monotonic()+20)
        java = selected.resolve(strict=True)
        if java.name != "java" or android.sha256(java) != tool["JavaExecutableSHA256"]:
            raise RuntimeError("预检入口摘要拒绝")
        with tempfile.TemporaryDirectory(prefix="java-identity-", dir=ROOT / ".test/three-platform-release") as temporary:
            source = Path(temporary) / "PublicIdentity.java"
            source.write_text('class PublicIdentity { public static void main(String[] args) throws Exception { Thread.sleep(2000); } }')
            argv = (str(java), str(source))
            env = android.build_environment()
            env["BETTBOX_PUBLIC_ENV_SENTINEL"] = "PUBLIC_ENV_NOT_ARGV"
            process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                time.sleep(0.1)
                executable = android.process_executable(process.pid)
                arguments = android.process_arguments(process.pid)
                facts["kernel_path_matches"] = executable == java
                facts["argv_matches"] = arguments == argv
                facts["environment_not_returned"] = all("PUBLIC_ENV_NOT_ARGV" not in item for item in arguments)
            finally:
                try:
                    facts["natural_exit"] = process.wait(timeout=15) == 0
                except subprocess.TimeoutExpired:
                    # 仅终止本脚本创建且尚未 wait 回收的直接子进程，不查找或终止其它进程。
                    process.kill()
                    facts["signals_sent"] = True
                    process.wait(timeout=5)
        facts["verified"] = all(facts.get(key) is True for key in
            ("kernel_path_matches", "argv_matches", "environment_not_returned", "natural_exit")) and not facts["signals_sent"]
    except Exception:
        facts["failure"] = "自有Java内核身份未满足预期"
    print(json.dumps(facts, ensure_ascii=False))
    return 0 if facts["verified"] else 1
if __name__ == "__main__":
    raise SystemExit(main())
