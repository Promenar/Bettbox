#!/usr/bin/env python3
"""真实Flutter引擎与固定生产内核的公开联调；未知owner保留，不强杀。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import time

import seal_macos_candidate as seal
import validate_desktop as desktop

ROOT = Path(__file__).resolve().parents[1]
MARKERS = tuple(f"BETTBOX_PROBE_{stage}_{generation}" for generation in (1, 2)
                for stage in ("READY", "RESULT", "STOP")) + ("BETTBOX_PROBE_PASS",)
TERMINALS = {"BETTBOX_PROBE_FAIL_CLEAN", "BETTBOX_PROBE_OWNER_UNKNOWN"}
PROBE_INPUTS = ("integration_test/macos_supervisor_probe.dart", "integration_test/probe_contract.dart")


def probe_hashes(root):
    result = {}
    for name in PROBE_INPUTS:
        relative = Path(name)
        descriptor, directory, before = seal.identity.open_public_file(root, relative)
        try:
            result[name] = seal.identity.hash_bound_file(descriptor)
            seal.identity.check_public_binding(root, relative, descriptor, directory, before)
        finally:
            os.close(descriptor); os.close(directory)
    return result


class MarkerReader:
    def __init__(self):
        self.buffer = bytearray(); self.markers = []; self.invalid = False
        self.skipping = False; self.bytes_seen = 0

    def add(self, data):
        self.bytes_seen += len(data)
        if self.bytes_seen > 131072: self.invalid = True
        for byte in data:
            if byte == 10:
                if not self.skipping:
                    line = bytes(self.buffer).decode("utf-8", errors="replace").rstrip("\r")
                    if line.startswith("BETTBOX_PROBE_"):
                        expected = MARKERS[len(self.markers)] if len(self.markers) < len(MARKERS) else None
                        if line not in TERMINALS and line != expected: self.invalid = True
                        if self.markers and self.markers[-1] in TERMINALS: self.invalid = True
                        if self.markers and self.markers[-1] == MARKERS[-1]: self.invalid = True
                        if line not in set(MARKERS) | TERMINALS:
                            self.invalid = True; line = "INVALID_MARKER"
                        if len(self.markers) < len(MARKERS) + 1: self.markers.append(line)
                        else: self.invalid = True
                self.buffer.clear(); self.skipping = False
            elif not self.skipping:
                self.buffer.append(byte)
                if len(self.buffer) > 1024:
                    if self.buffer.startswith(b"BETTBOX_PROBE_"): self.invalid = True
                    self.buffer.clear(); self.skipping = True

    def classification(self, code):
        if code is None: return "OWNER_RETAINED_UNKNOWN"
        if self.invalid or self.buffer.startswith(b"BETTBOX_PROBE_"): return "PROTOCOL_FAILED"
        if code == 0 and tuple(self.markers) == MARKERS: return "ACCEPTED"
        if code == 70 and self.markers and self.markers[-1] == "BETTBOX_PROBE_FAIL_CLEAN": return "CLEAN_FAILED"
        return "EXECUTION_FAILED"


def run_probe(executable, timeout=65, grace=15):
    process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=seal.ENV)
    reader = MarkerReader(); selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout; cancel_sent = False
    try:
        while selector.get_map() or process.poll() is None:
            if time.monotonic() >= deadline:
                if cancel_sent: break
                process.stdin.close(); cancel_sent = True; deadline = time.monotonic() + grace
            for key, _ in selector.select(0.1):
                data = os.read(key.fd, 512)
                if not data: selector.unregister(key.fileobj)
                else: reader.add(data)
        code = process.poll()
        classification = reader.classification(code)
        if cancel_sent and classification == "ACCEPTED": classification = "CANCELLED_EXITED"
        return {"classification": classification, "host_exit": code, "host_locator": process.pid,
                "markers": reader.markers, "cancel_sent": cancel_sent,
                "owner_retained_unknown": code is None}
    finally:
        selector.close()
        if not process.stdin.closed: process.stdin.close()
        process.stdout.close()
        # 只观察自己创建的host；不terminate/kill，不回收helper或Core。


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024): digest.update(chunk)
    return digest.hexdigest()


def tree_hashes(app):
    return {path.relative_to(app).as_posix(): sha(path)
            for path in sorted(app.rglob("*")) if path.is_file() and not path.is_symlink()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-name", required=True)
    parser.add_argument("--expected-core-sha256", required=True)
    parser.add_argument("--expected-helper-sha256", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"run-[a-z0-9-]{1,48}", args.output_name) or any(
            not re.fullmatch(r"[0-9a-f]{64}", item) for item in (args.expected_core_sha256, args.expected_helper_sha256)):
        raise RuntimeError("固定参数拒绝")
    output = ROOT / ".test/three-platform-release/macos-flutter-supervisor" / args.output_name
    seal.identity.public_parents(ROOT, output.parent.parent)
    output.parent.mkdir(exist_ok=True)
    seal.identity.public_parents(ROOT, output.parent)
    output.mkdir(mode=0o700)
    report = {"passed": False, "scope": "真实Flutter两代getIsInit和32个公开child退出；不含ClashService、账户流量或SC"}
    source = ROOT / seal.SOURCE
    original = output / "original-Bettbox.app"; built = output / "probe-unsigned-Bettbox.app"
    moved = False
    source_before = desktop.git_source_state(ROOT); locks = desktop.snapshot_locks(ROOT)
    probe_before = probe_hashes(ROOT)
    report["probe_input_sha256"] = probe_before
    try:
        seal.checked_tree(source)
        seal.identity.public_parents(ROOT, source.parent)
        original_hashes = tree_hashes(source)
        artifacts = {name: seal.artifact(source, name, identifier) for name, identifier in (
            ("BettboxCore", "com.appshub.bettbox.core"),
            ("BettboxCoreSupervisor", "com.appshub.bettbox.core.supervisor"))}
        if artifacts["BettboxCore"]["sha256"] != args.expected_core_sha256 or artifacts["BettboxCoreSupervisor"]["sha256"] != args.expected_helper_sha256:
            raise RuntimeError("固定输入摘要漂移")
        report["input_artifacts"] = artifacts
        report["original_host_sha256"] = sha(source / "Contents/MacOS/Bettbox")
        destinations = (ROOT / seal.PROBE_DESTINATION, (ROOT / seal.PROBE_DESTINATION).parent / "seal.json")
        if any(path.exists() or path.is_symlink() for path in destinations):
            raise RuntimeError("probe候选已存在")
        source.rename(original); moved = True
        flutter = shutil.which("flutter")
        if flutter is None: raise RuntimeError("Flutter工具不可用")
        env = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "LANG", "TMPDIR", "DEVELOPER_DIR") if key in os.environ}
        env["FLUTTER_XCODE_CODE_SIGNING_ALLOWED"] = "NO"
        argv = [flutter, "build", "macos", "--release", "--no-pub", "--target", "integration_test/macos_supervisor_probe.dart",
                "--dart-define=CORE_SHA256=" + args.expected_core_sha256, "--dart-define=APP_ENV=pre"]
        with (output / "build.log").open("wb") as log:
            result = subprocess.run(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900, check=False)
        if result.returncode: raise RuntimeError("Flutter构建失败")
        report["seal"] = seal.seal(ROOT, seal.PROBE_DESTINATION)
        report["execution"] = run_probe(ROOT / seal.PROBE_DESTINATION / "Contents/MacOS/Bettbox")
        report["passed"] = report["execution"]["classification"] == "ACCEPTED"
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
        report["failure"] = "LOCAL_PROBE_FAILED"
    finally:
        if moved:
            try:
                if source.exists(): source.rename(built)
                original.rename(source)
                report["original_restored"] = tree_hashes(source) == original_hashes
            except OSError:
                report["original_restored"] = False
        else: report["original_restored"] = True
        report["source_unchanged"] = desktop.source_state_unchanged(source_before, desktop.git_source_state(ROOT))
        report["locks_unchanged"] = desktop.evaluate_locks(ROOT, locks)[0]
        try: report["probe_inputs_unchanged"] = probe_hashes(ROOT) == probe_before
        except (RuntimeError, OSError): report["probe_inputs_unchanged"] = False
        if not all(report[key] for key in ("original_restored", "source_unchanged", "locks_unchanged", "probe_inputs_unchanged")): report["passed"] = False
        (output / "RESULT.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print("FLUTTER_SUPERVISOR_PASS" if report["passed"] else "FLUTTER_SUPERVISOR_FAIL")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try: raise SystemExit(main())
    except (RuntimeError, OSError):
        print("FLUTTER_SUPERVISOR_SETUP_REJECTED"); raise SystemExit(1)
