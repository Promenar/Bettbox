#!/usr/bin/env python3
"""逐进程验证生产JNI释放回调；只返回公开固定字段，不记录工具原文。"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FIELDS = {"case", "result", "followup_result", "get_env", "attach", "detach", "delete", "checks", "clears", "protect_jni", "resolve_jni", "failed"}


def no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run(phase):
    folder = ROOT / ".test/android-checked-release-jni"
    binary = folder / ("fixture-" + phase)
    for path in (binary, folder, folder.parent):
        if path.is_symlink():
            raise RuntimeError("公开夹具路径无效")
    if not binary.is_file():
        raise RuntimeError("公开夹具未编译")
    results = []
    for case in range(1, 13 if phase == "red" else 18):
        item = {"case": case, "passed": False}
        try:
            process = subprocess.run([str(binary), str(case)], cwd=ROOT,
                                     env={"PATH": "/usr/bin:/bin"}, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, timeout=10, check=False,
                                     preexec_fn=no_core_dump)
            item["exit"] = process.returncode
            if len(process.stdout) <= 2048:
                data = json.loads(process.stdout)
                if (isinstance(data, dict) and set(data) == FIELDS and
                        all(type(value) is int and -1000 <= value <= 1000 for value in data.values()) and
                        data["case"] == case and data["failed"] in (0, 1)):
                    item["counts"] = data
                    item["passed"] = process.returncode == 0 and data["failed"] == 0
        except (OSError, subprocess.SubprocessError, ValueError):
            item["execution_unconfirmed"] = True
        results.append(item)
    report = {"schema": 1, "phase": phase, "fixture_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "actual_JVM": False, "cases": results,
              "passed": all(item["passed"] for item in results)}
    (folder / ("result-" + phase + ".json")).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"cases": len(results), "failed": sum(not item["passed"] for item in results),
                      "passed": report["passed"], "actual_JVM": False}, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="公开JNI回调收尾验收")
    parser.add_argument("--phase", choices=("red", "red-expanded", "green"), required=True)
    args = parser.parse_args()
    try:
        raise SystemExit(run(args.phase))
    except (OSError, RuntimeError):
        print("JNI_RELEASE_FIXTURE_UNCONFIRMED")
        raise SystemExit(1)
