#!/usr/bin/env python3
"""真实Go Core的签名、握手、只读业务动作及原生退出验证；不启用代理。"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import runner


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-core-sha256", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{64}", args.expected_core_sha256):
        raise runner.FixedFailure("CORE_HASH_ARGUMENT_REJECTED")
    core = runner.REPO / ".test/three-platform-release/core-owned-process"
    if core.is_symlink() or runner.sha(core) != args.expected_core_sha256:
        raise runner.FixedFailure("CORE_SOURCE_DRIFT")
    output = runner.REPO / ".test/three-platform-release/macos-supervisor-real-go"
    output.mkdir(mode=0o700)
    report = {"passed": False, "scope": "真实Mihomo getIsInit；不含Flutter、有效订阅流量或系统代理"}
    try:
        snapshot, before = runner.snapshot_sources(output)
        report["source_hashes_before"] = before
        frozen = output / "frozen-core"
        frozen.write_bytes(core.read_bytes())
        if runner.sha(frozen) != args.expected_core_sha256:
            raise runner.FixedFailure("CORE_COPY_DRIFT")
        report["unsigned_core_sha256"] = args.expected_core_sha256
        case = output / "positive"; case.mkdir(mode=0o700)
        host, baseline = runner.build(case, snapshot, real_core=frozen)
        report["signed_artifacts"] = baseline
        report["execution"] = runner.run_case(host)
        # 仅保留固定fixture路径的存活数量，绝不输出其它进程或命令行。
        raw = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,comm="],
                             env=runner.ENV, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=5, check=True).stdout.decode("utf-8", errors="replace")
        names = {str(host.parent / name) for name in ("Bettbox", "BettboxCore", "BettboxCoreSupervisor")}
        report["remaining_fixture_processes"] = sum(
            len(parts := line.strip().split(None, 1)) == 2 and parts[1] in names
            for line in raw.splitlines())
        report["passed"] = report["execution"]["classification"] == "ACCEPTED" and report["remaining_fixture_processes"] == 0
    except (runner.FixedFailure, OSError, subprocess.SubprocessError) as error:
        report["failure"] = str(error) if isinstance(error, runner.FixedFailure) else "LOCAL_EXECUTION_FAILED"
    finally:
        report["source_hashes_after"] = runner.current_hashes()
        if report["source_hashes_after"] != report.get("source_hashes_before") or runner.sha(core) != args.expected_core_sha256:
            report["passed"] = False; report["source_drift"] = True
        (output / "RESULT.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("REAL_GO_CHAIN_PASS" if report["passed"] else "REAL_GO_CHAIN_FAIL")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try: raise SystemExit(main())
    except (runner.FixedFailure, OSError):
        print("REAL_GO_SETUP_REJECTED"); raise SystemExit(1)
