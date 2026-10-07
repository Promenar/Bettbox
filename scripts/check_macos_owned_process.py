#!/usr/bin/env python3
"""仅用公开协议帧验收任务自有 macOS 子进程，不调用业务动作。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import stat
import struct
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".test/three-platform-release/core-owned-process"
RECEIPT = ROOT / ".test/three-platform-release/macos-owned-process.json"
HELLO = {"type": "hello", "protocol": 1, "generation": 1}


def frame(value):
    payload = json.dumps(value, separators=(",", ":")).encode()
    return struct.pack("<I", len(payload)) + payload


def read_exact(fd, size, deadline):
    data = bytearray()
    while len(data) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise RuntimeError("控制帧超时")
        chunk = os.read(fd, size - len(data))
        if not chunk:
            raise RuntimeError("控制帧截断")
        data.extend(chunk)
    return bytes(data)


def ack(fd):
    deadline = time.monotonic() + 3
    size = struct.unpack("<I", read_exact(fd, 4, deadline))[0]
    if not 0 < size <= 4096:
        raise RuntimeError("首帧长度拒绝")
    value = json.loads(read_exact(fd, size, deadline))
    if value != {"type": "ack", "protocol": 1, "generation": 1}:
        raise RuntimeError("首帧协议拒绝")


def filled_pipe():
    reader, writer = os.pipe()
    os.set_blocking(writer, False)
    total = 0
    try:
        while total < 16 * 1024 * 1024:
            try:
                total += os.write(writer, b"PUBLIC_FIXTURE" * 256)
            except BlockingIOError:
                break
        else:
            raise RuntimeError("未建立满管道fixture")
        os.set_blocking(writer, True)
    except BaseException:
        cleanup_owned(None, [reader, writer])
        raise
    return reader, writer, total


def binary_identity(expected_sha):
    before = BINARY.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_mode & 0o022:
        raise RuntimeError("任务产物身份拒绝")
    digest = hashlib.sha256(BINARY.read_bytes()).hexdigest()
    after = BINARY.lstat()
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) or digest != expected_sha:
        raise RuntimeError("任务产物漂移")
    return identity


def cleanup_owned(child, owned_fds):
    errors = []
    if child is not None:
        try:
            if child.poll() is None:
                try:
                    child.kill()
                except OSError:
                    errors.append("终止失败")
                try:
                    child.wait(timeout=3)
                except (OSError, subprocess.TimeoutExpired):
                    errors.append("退出未确认")
        except OSError:
            errors.append("进程状态未确认")
        for stream in (child.stdin, child.stdout):
            if stream is not None:
                try:
                    stream.close()
                except (OSError, ValueError):
                    errors.append("流关闭失败")
    for fd in owned_fds:
        try:
            os.close(fd)
        except OSError:
            errors.append("句柄关闭失败")
    return errors


def run_case(name, mode, expected_sha=None, identity=None):
    owned_fds = []
    child = None
    count = 0
    result = {"name": name, "passed": False}
    try:
        # main绑定外部指定SHA；默认值仅供本地异常路径单元测试。
        expected_sha = expected_sha or hashlib.sha256(BINARY.read_bytes()).hexdigest()
        before = binary_identity(expected_sha)
        if identity is not None and before != identity:
            raise RuntimeError("任务产物身份漂移")
        output = subprocess.PIPE
        error = subprocess.DEVNULL
        if mode in ("full-stdout", "full-stderr"):
            reader, writer, count = filled_pipe()
            owned_fds.extend((reader, writer))
            if mode == "full-stdout":
                output = writer
            else:
                error = writer
        child = subprocess.Popen(
            [str(BINARY), "--owned-pipe-v1"],
            cwd=ROOT / ".test/three-platform-release",
            env={"PATH": os.defpath},
            stdin=subprocess.PIPE, stdout=output, stderr=error,
            close_fds=True,
        )
        child.stdin.write(frame({"type": "unexpected"}) if mode == "invalid" else frame(HELLO))
        child.stdin.flush()
        first_frame = False
        if mode not in ("invalid", "full-stdout"):
            ack(child.stdout.fileno())
            first_frame = True
        if mode == "wrong-generation":
            child.stdin.write(frame({"protocol": 1, "generation": 2,
                                     "action": {"id": "public-fixture", "method": "invalid", "data": None}}))
            child.stdin.flush()
        child.stdin.close()
        code = child.wait(timeout=8)
        expected = 1 if mode in ("invalid", "full-stdout", "wrong-generation") else 0
        result.update(passed=code == expected, exit_code=code, expected_exit_code=expected,
                      ack_verified=first_frame, prefilled_bytes=count, forced_termination=False)
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
        result.update(error="协议或进程验收失败", forced_termination=child is not None and child.poll() is None)
    finally:
        errors = cleanup_owned(child, owned_fds)
        result["cleanup_verified"] = not errors
        if errors:
            result.update(passed=False, cleanup_errors=errors)
        if expected_sha is not None:
            try:
                if binary_identity(expected_sha) != before:
                    raise RuntimeError("任务产物身份漂移")
                result["binary_stable"] = True
            except (OSError, RuntimeError, UnboundLocalError):
                result.update(passed=False, binary_stable=False)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-sha256", required=True)
    args = parser.parse_args()
    receipt = {"status": "failed", "binary_sha256": args.expected_sha256, "cases": [],
               "valid_business_actions_sent": 0, "wrong_generation_envelopes_sent": 1,
               "raw_stdout_or_stderr_retained": False, "native_identity_bridge_verified": False,
               "system_proxy_changed": False, "race_verified": False}
    # 覆盖旧状态，再执行；失败不得留下上轮passed回执。
    RECEIPT.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    try:
        identity = binary_identity(args.expected_sha256)
        receipt["cases"] = [run_case(name, mode, args.expected_sha256, identity) for name, mode in (
            ("handshake-and-eof", "normal"),
            ("invalid-first-frame", "invalid"),
            ("wrong-generation", "wrong-generation"),
            ("full-control-output", "full-stdout"),
            ("full-log-output", "full-stderr"),
        )]
        if all(x["passed"] for x in receipt["cases"]):
            receipt["status"] = "passed"
    except (OSError, RuntimeError):
        receipt["error"] = "任务产物绑定失败"
    RECEIPT.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": receipt["status"], "cases": len(receipt["cases"])}, ensure_ascii=False))
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
