#!/usr/bin/env python3
"""只验证普通宿主的系统配置锁权限，不暂存、提交或应用代理配置。"""
import json
from pathlib import Path
import platform
import subprocess
import tempfile

SOURCE = r'''import Foundation
import SystemConfiguration
@main struct Probe {
    static func main() {
        guard let preferences = SCPreferencesCreate(nil, "Bettbox lock permission probe" as CFString, nil),
              let before = SCPreferencesGetSignature(preferences) else {
            print("{\"status\":\"readFailed\"}"); return
        }
        let locked = SCPreferencesLock(preferences, false)
        let code = locked ? 0 : SCError()
        let unlocked = !locked || SCPreferencesUnlock(preferences)
        SCPreferencesSynchronize(preferences)
        let unchanged = SCPreferencesGetSignature(preferences).map { ($0 as Data) == (before as Data) } ?? false
        let status = locked ? "locked" : code == kSCStatusAccessError ? "permissionDenied" : "lockFailed"
        let report: [String: Any] = ["status": status, "unlocked": unlocked, "preferencesUnchanged": unchanged, "systemConfigurationWritten": false]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}'''

def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('仅适用于已授权本机macOS arm64')
    root = Path(__file__).resolve().parents[1]
    directory = root / '.test/three-platform-release'
    directory.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='sc-lock-probe-', dir=directory))
    source = work / 'probe.swift'; source.write_text(SOURCE)
    binary = work / 'probe'
    result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(source), '-framework', 'SystemConfiguration', '-o', str(binary)], capture_output=True, timeout=60)
    if result.returncode != 0:
        (work / 'compile.log').write_bytes(result.stdout + result.stderr)
        print(json.dumps({'status': 'compileFailed', 'exit_code': result.returncode})); return 1
    result = subprocess.run([str(binary)], capture_output=True, timeout=15)
    if result.returncode != 0:
        print(json.dumps({'status': 'probeFailed', 'exit_code': result.returncode})); return 1
    report = json.loads(result.stdout)
    (work / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'report': report, 'receipt': str((work / 'report.json').relative_to(root))}, ensure_ascii=False))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
