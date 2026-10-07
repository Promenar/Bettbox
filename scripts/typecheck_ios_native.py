#!/usr/bin/env python3
"""使用现有 Flutter/Xcode 检查 iOS 原生类型，不安装依赖、签名或运行 VPN。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    flutter = shutil.which('flutter')
    if not flutter:
        raise SystemExit('当前任务 PATH 未提供 Flutter')
    engine = Path(flutter).resolve().parents[1] / 'bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator'
    if not (engine / 'Flutter.framework/Modules/module.modulemap').is_file():
        raise SystemExit('现有 Flutter 模拟器框架缺失，不自动下载')
    sources = [root / name for name in (
        'ios/Shared/CoreClient.swift', 'ios/Shared/SnapshotNetwork.swift',
        'ios/Shared/SnapshotStore.swift', 'ios/PacketTunnel/PacketTunnelProvider.swift',
        'ios/Runner/BettboxIOSPlugin.swift',
    )]
    headers = root / 'ios/Vendor/BettboxCore.xcframework/ios-arm64-simulator/Headers'
    tracked = sources + [headers / 'module.modulemap', headers / 'BettboxCore.h']
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked}
    argv = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-typecheck', '-target',
            'arm64-apple-ios15.0-simulator', '-I', str(headers), '-F', str(engine)] + [str(path) for path in sources]
    if not args.execute:
        print('计划：现有 Simulator SDK、Flutter.framework 与 BettboxCore；共享源码、Runner插件及PacketTunnel类型检查。')
        return
    receipt = {'scope': 'ios-native-sdk-typecheck', 'status': 'failed', 'source_hashes': hashes,
               'vpn_verified': False, 'signed': False}
    directory = root / '.test/three-platform-release'
    directory.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(argv, cwd=root, capture_output=True, timeout=180)
        (directory / 'ios-native-typecheck.log').write_bytes(result.stdout + result.stderr)
        unchanged = all(path.is_file() and not path.is_symlink() and
                        hashlib.sha256(path.read_bytes()).hexdigest() == hashes[str(path.relative_to(root))]
                        for path in tracked)
        receipt.update(source_unchanged=unchanged, exit_code=result.returncode,
                       status='passed' if result.returncode == 0 and unchanged else 'failed')
    finally:
        (directory / 'ios-native-typecheck.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'status': receipt['status'], 'source_unchanged': receipt.get('source_unchanged', False)}, ensure_ascii=False))
    if receipt['status'] != 'passed':
        raise SystemExit('原生类型检查失败；请检查本项目固定源码的编译诊断日志')


if __name__ == '__main__':
    main()
