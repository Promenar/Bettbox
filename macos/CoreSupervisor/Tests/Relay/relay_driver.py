#!/usr/bin/env python3
"""公开验收驱动：只接受调用者提供的已构建helper，stdout仅汇报布尔验收。"""
import argparse
import json
import os
import select
import struct
import subprocess
import time
import uuid

LIMIT = 10 * 1024 * 1024

def encode(value):
    raw = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()
    return struct.pack("<I", len(raw)) + raw

def read_exact(fd, count, expiry):
    result = bytearray()
    while len(result) < count:
        remaining = expiry - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError("帧超时")
        part = os.read(fd, count - len(result))
        if not part:
            raise EOFError("帧结束")
        result.extend(part)
    return bytes(result)

def receive(fd, seconds=6):
    expiry = time.monotonic() + seconds
    size, = struct.unpack("<I", read_exact(fd, 4, expiry))
    assert 0 < size <= LIMIT
    return json.loads(read_exact(fd, size, expiry))

def send(fd, value, partial=False):
    raw = encode(value)
    expiry = time.monotonic() + 30
    for offset in range(0, len(raw), 1 if partial else 65536):
        chunk = memoryview(raw)[offset: offset + (1 if partial else 65536)]
        while chunk:
            remaining = expiry - time.monotonic()
            if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
                raise TimeoutError("写帧超时")
            try:
                written = os.write(fd, chunk)
                chunk = chunk[written:]
            except BlockingIOError:
                pass

def stage(kind, generation, **extra):
    return dict(type=kind, protocol=1, generation=generation, **extra)

def start(args):
    env = dict(os.environ)
    if args.fake_fault:
        env["RELAY_FAKE"] = args.fake_fault
    return subprocess.Popen([args.helper, "--owned-supervisor-v1", "--generation", "7"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)

def handshake(child, partial=False):
    inp, out = child.stdin.fileno(), child.stdout.fileno()
    os.set_blocking(inp, False)
    assert receive(out) == stage("supervisor_ready", 7)
    launch = str(uuid.uuid4())
    send(inp, stage("prepare_core", 7, launch=launch), partial)
    ready = receive(out)
    assert ready["type"] == "core_ready" and ready["launch"] == launch and ready["generation"] == 7
    send(inp, stage("hello", 7), partial)
    assert receive(out) == stage("ack", 7)
    return inp, out

def action(args, data):
    return dict(protocol=1, generation=7, action=dict(id="probe", method=args.method, data=data))

def wait_exit(child, expected_failure):
    code = child.wait(timeout=12)
    assert (code != 0) == expected_failure
    return code

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True)
    parser.add_argument("--case", required=True, choices=["partial", "credit", "fullpipe-close", "half-host", "paused-hup", "pending-host-eof", "fault"])
    parser.add_argument("--method", default="probe", help="生产验收须指定已确认安全的实际Go业务method")
    parser.add_argument("--fake-fault", choices=["late-initial", "initial-reject", "late-core", "core-reject", "counterfeit-credit", "half-result", "fullpipe-result", "hup-while-paused"])
    args = parser.parse_args()
    child = start(args)
    # 驱动不kill helper；超时留下进程供owner状态调查。
    if args.case == "fault" and args.fake_fault in {"late-initial", "initial-reject", "late-core", "core-reject"}:
        try:
            handshake(child)
        except (EOFError, TimeoutError, BrokenPipeError):
            pass
        wait_exit(child, True)
    else:
        inp, out = handshake(child, args.case == "partial")
        if args.case == "paused-hup":
            assert args.fake_fault == "hup-while-paused"
            send(inp, action(args, None))
            # host输出不消费，result超过pipe容量；Core已完成写入后关闭stdout且保持存活。
            time.sleep(1)
            assert child.poll() is None, "暂停Core读取时HUP提前结束helper"
            events = [receive(out, 12), receive(out, 12)]
            results = [e for e in events if set(e) == {"protocol", "generation", "result"}]
            assert len(results) == 1 and len(results[0]["result"]["data"]) == LIMIT - 1024
            assert stage("relay_credit", 7, sequence=1) in events
            wait_exit(child, True)
        elif args.case == "pending-host-eof":
            assert args.fake_fault == "fullpipe-result"
            send(inp, action(args, None))
            time.sleep(1)
            assert child.poll() is None
            child.stdin.close()
            # 已读到relay的result/credit未交付，取消可回收但必须固定失败。
            wait_exit(child, True)
        elif args.case == "half-host":
            os.write(inp, struct.pack("<I", 100) + b"{")
            child.stdin.close()
            wait_exit(child, True)
        elif args.case == "fullpipe-close":
            # 输入写满时输出不消费；合法第1帧后故意不等待credit送第2帧。
            # native HUP必须绕开业务读取许可并持续推进owner回收。
            raw = encode(action(args, "x" * (LIMIT - 1024)))
            send(inp, action(args, "x" * (LIMIT - 1024)))
            expiry = time.monotonic() + 2
            offset = 0
            blocked = False
            while time.monotonic() < expiry:
                try:
                    offset += os.write(inp, raw[offset:])
                    if offset == len(raw):
                        offset = 0
                except BlockingIOError:
                    blocked = True
                    time.sleep(.001)
            assert blocked, "未建立背压"
            child.stdin.close()
            child.stdout.close()
            wait_exit(child, True)
        else:
            send(inp, action(args, None), args.case == "partial")
            if args.case == "fault":
                wait_exit(child, True)
            else:
                events = [receive(out), receive(out)]
                credit = [e for e in events if e.get("type") == "relay_credit"]
                results = [e for e in events if set(e) == {"protocol", "generation", "result"}]
                assert credit == [stage("relay_credit", 7, sequence=1)] and len(results) == 1
                send(inp, action(args, None))
                second = [receive(out), receive(out)]
                assert stage("relay_credit", 7, sequence=2) in second
                child.stdin.close()
                wait_exit(child, False)
    print(json.dumps({"case": args.case, "passed": True, "sdk_proven": False if args.fake_fault else "须由签名链证据单独确认"}, ensure_ascii=False))

if __name__ == "__main__":
    main()
