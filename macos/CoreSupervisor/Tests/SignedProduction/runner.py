#!/usr/bin/env python3
"""production helper与真实host ABI的公开签名fixture；未知owner不跨进程强杀。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
HELPER_ROOT = "macos/CoreSupervisor"
HOST_ROOT = "macos/CoreSupervisor/Host"
HELPER_FILES = (
    "Bridge.h", "Identity/SSIAuthority.swift", "Identity/SSIAppleBackend.swift", "Identity/SSIFile.swift", "Identity/SSIBridge.h",
    "Owner/OwnedBackend.c", "Owner/OwnedBackend.h", "Owner/SystemBackend.swift", "Owner/SupervisorLifecycle.swift",
    "Relay/HelperC.c", "Relay/HelperC.h", "Relay/RelayCodec.swift", "Relay/SDKMailbox.swift", "Relay/RelayMain.swift", "Relay/main.swift")
HOST_FILES = ("HostSupervisorAuthority.swift", "HostSupervisorProduction.swift")
POSITIVE = b"HANDSHAKE_OK\nCREDIT_RESULT_OK\nSTOP0_NATIVE_GONE\nFIXTURE_OK\n"
NEGATIVE = b"FIXTURE_REJECTED\n"

class FixedFailure(Exception): pass

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def tool(args, log_path=None):
    try: result = subprocess.run(args, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired): raise FixedFailure("TOOL_UNAVAILABLE_OR_TIMEOUT") from None
    if log_path is not None: log_path.write_bytes(result.stdout + result.stderr)
    if result.returncode: raise FixedFailure("TOOL_FAILED")
    return result

def sign(path, identifier):
    tool(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier, str(path)])

def public_signature(binary):
    data = tool(["/usr/bin/codesign", "-d", "--verbose=4", str(binary)]).stderr.decode("utf-8", errors="replace")
    ids = re.findall(r"^Identifier=(.+)$", data, re.M); cds = re.findall(r"^CDHash=([0-9a-f]{40})$", data, re.M)
    if len(ids) != 1 or len(cds) != 1 or not re.search(r"^Signature=adhoc$", data, re.M):
        raise FixedFailure("PUBLIC_SIGNATURE_FIELDS_REJECTED")
    return {"sha256": sha(binary), "identifier": ids[0], "cdhash": cds[0], "signingmode": "adhoc"}

def identity_manifest(binary, identifier, destination):
    fields = public_signature(binary)
    if fields["identifier"] != identifier: raise FixedFailure("FIXED_IDENTIFIER_REJECTED")
    fields["schema"] = 1
    destination.write_text(json.dumps(fields, sort_keys=True) + "\n")
    return fields

def sources():
    return [HELPER_ROOT + "/" + name for name in HELPER_FILES] + [HOST_ROOT + "/" + name for name in HOST_FILES]

def current_hashes(): return {name: sha(REPO / name) for name in sources()}

def snapshot_sources(output):
    base = json.loads((HERE / "BASE.json").read_text())
    expected = base["source_hashes"]
    if any(sha(HERE / name) != expected_sha for name, expected_sha in base["fixture_source_hashes"].items()):
        raise FixedFailure("FIXTURE_SOURCE_DRIFT")
    before = current_hashes()
    if before != expected: raise FixedFailure("SOURCE_DRIFT_BEFORE_EXECUTION")
    snapshot = output / "source-snapshot"; snapshot.mkdir(mode=0o700)
    for name, expected_sha in before.items():
        data = (REPO / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected_sha: raise FixedFailure("SOURCE_COPY_DRIFT")
        target = snapshot / name; target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes(data)
    for name in ("main.swift", "Core.c"):
        target = snapshot / "fixture" / name; target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes((HERE / name).read_bytes())
    return snapshot, before

def build(case, source):
    app = case / "Bettbox.app"; macos = app / "Contents/MacOS"; resources = app / "Contents/Resources"
    macos.mkdir(parents=True, mode=0o700); resources.mkdir(mode=0o700)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.appshub.bettbox",
        "CFBundleExecutable": "Bettbox", "CFBundleName": "Bettbox", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"}))
    actual = source / HELPER_ROOT; host_source = source / HOST_ROOT; public = source / "fixture"
    clang = ["/usr/bin/xcrun", "clang", "-target", "arm64-apple-macos12", "-Wall", "-Wextra", "-Werror"]
    core = macos / "BettboxCore"; helper = macos / "BettboxCoreSupervisor"; host = macos / "Bettbox"
    tool(clang + [str(public / "Core.c"), "-o", str(core)])
    owned = case / "owned.o"; relay = case / "relay.o"
    tool(clang + ["-I", str(actual), "-c", str(actual / "Owner/OwnedBackend.c"), "-o", str(owned)])
    tool(clang + ["-I", str(actual), "-c", str(actual / "Relay/HelperC.c"), "-o", str(relay)])
    swift = ["/usr/bin/xcrun", "swiftc", "-target", "arm64-apple-macos12", "-I", str(actual),
             "-import-objc-header", str(actual / "Relay/HelperC.h")]
    identity = [str(actual / "Identity" / name) for name in ("SSIAuthority.swift", "SSIAppleBackend.swift", "SSIFile.swift")]
    production = identity + [str(actual / "Owner" / name) for name in ("SystemBackend.swift", "SupervisorLifecycle.swift")]
    production += [str(actual / "Relay" / name) for name in ("RelayCodec.swift", "SDKMailbox.swift", "RelayMain.swift", "main.swift")]
    # 无fake/PublicFixture宏，helper main、owner、relay均来自actual冻结快照。
    tool(swift + production + [str(owned), str(relay), "-framework", "Security", "-framework", "Foundation", "-lproc", "-o", str(helper)], case / "helper-compile.log")
    host_files = identity + [str(host_source / name) for name in HOST_FILES] + [str(actual / "Relay/RelayCodec.swift"), str(public / "main.swift")]
    tool(swift + host_files + [str(relay), "-framework", "Security", "-framework", "Foundation", "-lproc", "-o", str(host)], case / "host-compile.log")
    sign(core, "com.appshub.bettbox.core"); sign(helper, "com.appshub.bettbox.core.supervisor")
    baseline = {}
    for binary, identifier in ((core, "com.appshub.bettbox.core"), (helper, "com.appshub.bettbox.core.supervisor")):
        baseline[binary.name] = identity_manifest(binary, identifier, resources / (binary.name + "Identity.json"))
    sign(app, "com.appshub.bettbox")
    return host, baseline

def run_case(host, timeout=30, grace=12):
    process = subprocess.Popen([str(host)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=ENV)
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    output = b""; deadline = time.monotonic() + timeout; stopping = False; io_failed = False
    try:
        while selector.get_map() or process.poll() is None:
            if time.monotonic() >= deadline:
                if not stopping:
                    stopping = True; process.stdin.close(); deadline = time.monotonic() + grace
                else: break
            for key, _ in selector.select(0.1):
                data = os.read(key.fd, 512)
                if not data: selector.unregister(key.fileobj); continue
                if len(output) + len(data) > 4096:
                    io_failed = True
                    if not stopping:
                        stopping = True; process.stdin.close(); deadline = time.monotonic() + grace
                    continue
                output += data
        code = process.poll()
        if code is None:
            classification = "TIMEOUT_OWNER_RETAINED"
        elif stopping:
            classification = "SUPERVISED_TIMEOUT_EXITED"
        elif not io_failed and code == 0 and output == POSITIVE:
            classification = "ACCEPTED"
        elif not io_failed and code == 70 and output == NEGATIVE:
            classification = "REJECTED"
        else: classification = "EXECUTION_FAILED"
        # 不持久化原始stdout。固定阶段boolean只描述本fixture明确输出，nativegone需要完整positive。
        return {"classification": classification, "host_exit": code,
                "handshake": output.startswith(b"HANDSHAKE_OK\n"),
                "native_confirmed_gone": classification == "ACCEPTED",
                "owner_retained_unknown": code is None}
    finally:
        selector.close()
        if not process.stdin.closed: process.stdin.close()
        process.stdout.close()
        # 不调用terminate/kill、不发signal、不回收helper/Core；未知出生一律保留失败。

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--output-name", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"run-[a-z0-9-]{1,48}", args.output_name): raise FixedFailure("OUTPUT_NAME_REJECTED")
    base_output = REPO / ".test/three-platform-release/macos-supervisor-production"
    base_output.mkdir(parents=True, exist_ok=True, mode=0o700)
    output = base_output / args.output_name; output.mkdir(mode=0o700)
    report = {"cases": {}, "passed": False, "execution": "PUBLIC_PRODUCTION_HELPER_FIXTURE"}
    try:
        snapshot, before = snapshot_sources(output); report["source_hashes_before"] = before
        sdk = tool(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]).stdout.decode().strip()
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", sdk): raise FixedFailure("SDK_METADATA_REJECTED")
        report["sdk_version"] = sdk
        for name in ("positive", "core-manifest-tamper", "helper-wrong-id"):
            case = output / name; case.mkdir(mode=0o700)
            host, baseline = build(case, snapshot)
            if name == "core-manifest-tamper":
                resource = host.parent.parent / "Resources/BettboxCoreIdentity.json"
                resource.write_bytes(resource.read_bytes() + b" ")
            if name == "helper-wrong-id":
                binary = host.parent / "BettboxCoreSupervisor"; sign(binary, "com.appshub.bettbox.fixture.wrong")
                fields = public_signature(binary); fields.update({"schema": 1, "identifier": "com.appshub.bettbox.core.supervisor"})
                (host.parent.parent / "Resources/BettboxCoreSupervisorIdentity.json").write_text(json.dumps(fields, sort_keys=True) + "\n")
                sign(host.parent.parent.parent, "com.appshub.bettbox")
            execution = {binary: public_signature(host.parent / binary) for binary in ("Bettbox", "BettboxCoreSupervisor", "BettboxCore")}
            manifests = {binary: sha(host.parent.parent / "Resources" / (binary + "Identity.json")) for binary in ("BettboxCore", "BettboxCoreSupervisor")}
            record = run_case(host); record["baseline_signed_artifacts"] = baseline
            record["execution_artifacts"] = execution; record["execution_manifest_sha256"] = manifests
            expected = "ACCEPTED" if name == "positive" else "REJECTED"
            record["expected"] = expected; record["passed"] = record["classification"] == expected
            report["cases"][name] = record
            if record["owner_retained_unknown"]: raise FixedFailure("OWNER_RECOVERY_REQUIRED")
        report["passed"] = all(item["passed"] for item in report["cases"].values())
    except FixedFailure as error:
        report["failure"] = str(error)
    finally:
        try:
            after = current_hashes(); report["source_hashes_after"] = after
            if after != report.get("source_hashes_before"):
                report["passed"] = False; report["source_drift"] = True
        except OSError:
            report["passed"] = False; report["source_drift"] = True
        (output / "RESULT.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("FIXTURE_MATRIX_PASS" if report["passed"] else "FIXTURE_MATRIX_FAIL")
    return 0 if report["passed"] else 1

if __name__ == "__main__":
    try: raise SystemExit(main())
    except (FixedFailure, OSError):
        print("FIXTURE_SETUP_REJECTED"); raise SystemExit(1)
