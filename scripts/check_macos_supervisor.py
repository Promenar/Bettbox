#!/usr/bin/env python3
"""验证 macOS supervisor 原生模块；不启动客户端、签名或修改系统代理。"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile


SOURCE_NAMES = (
    'Identity/SSIAuthority.swift', 'Identity/SSIAppleBackend.swift',
    'Identity/SSIFile.swift', 'Identity/SSIBridge.h',
    'Owner/OwnedBackend.c', 'Owner/OwnedBackend.h',
    'Owner/SupervisorLifecycle.swift', 'Owner/SystemBackend.swift',
    'Tests/main.swift', 'Tests/SSIFixtures.swift',
    'Tests/OwnerTests.swift', 'Tests/PublicProcessFixture.swift', 'Tests/KernelLiveness.c', 'Bridge.h',
    'Relay/RelayCodec.swift', 'Relay/HelperC.h', 'Relay/HelperC.c',
    'Relay/SDKMailbox.swift', 'Relay/RelayMain.swift', 'Relay/main.swift',
    'Tests/Relay/Bridge.h', 'Tests/Relay/CodecMain.swift', 'Tests/Relay/FakeRuntime.swift',
    'Tests/Relay/relay_driver.py', 'Host/HostSupervisorAuthority.swift',
    'Host/HostSupervisorProduction.swift', 'Host/HostSupervisorFlutter.swift',
    'Tests/HostSupervisorAuthorityTests.swift',
)


def hashes(root):
    result = {}
    for name in SOURCE_NAMES:
        path = root / 'macos/CoreSupervisor' / name
        if not path.is_file() or path.is_symlink():
            raise ValueError('原生固定源码缺失或为符号链接')
        result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def commands(root, work, sdk):
    source = root / 'macos/CoreSupervisor'
    identity, owner, tests = [source / name for name in ('Identity', 'Owner', 'Tests')]
    object_file = work / 'backend.o'
    swift = ['xcrun', 'swiftc', '-target', 'arm64-apple-macos12', '-sdk', sdk]
    result = [
        ('c-syntax', ['xcrun', 'clang', '-target', 'arm64-apple-macos12', '-isysroot', sdk,
                      '-Wall', '-Wextra', '-Werror', '-fsyntax-only', str(owner / 'OwnedBackend.c')]),
        ('c-object', ['xcrun', 'clang', '-target', 'arm64-apple-macos12', '-isysroot', sdk,
                      '-DOWNED_PUBLIC_FIXTURE', '-Wall', '-Wextra', '-Werror', '-c',
                      str(owner / 'OwnedBackend.c'), '-o', str(object_file)]),
    ]
    identity_binary = work / 'identity-fixtures'
    result.extend([
        ('identity-compile', swift + ['-import-objc-header', str(identity / 'SSIBridge.h')]
         + [str(identity / name) for name in ('SSIAuthority.swift', 'SSIAppleBackend.swift', 'SSIFile.swift')]
         + [str(tests / name) for name in ('SSIFixtures.swift', 'main.swift')]
         + ['-framework', 'Security', '-framework', 'CryptoKit', '-lproc', '-o', str(identity_binary)]),
        ('identity-run', [str(identity_binary)]),
    ])
    for kind, main in [('owner-fake', 'OwnerTests.swift'), ('owner-process', 'PublicProcessFixture.swift')]:
        binary = work / kind
        result.extend([
            (kind + '-compile', swift + ['-D', 'OWNED_PUBLIC_FIXTURE', '-Xcc',
             '-DOWNED_PUBLIC_FIXTURE', '-import-objc-header', str(owner / 'OwnedBackend.h')]
             + [str(owner / name) for name in ('SupervisorLifecycle.swift', 'SystemBackend.swift')]
             + [str(tests / main), str(object_file), '-lproc', '-o', str(binary)]),
            (kind + '-run', [str(binary)]),
        ])
    relay = source / 'Relay'
    relay_object = work / 'relay.o'
    fixture_object = work / 'relay-fixture.o'
    clang = ['xcrun', 'clang', '-target', 'arm64-apple-macos12', '-isysroot', sdk, '-Wall', '-Wextra', '-Werror']
    result.extend([
        ('kernel-compile', clang + [str(tests / 'KernelLiveness.c'), '-lproc', '-o', str(work / 'kernel-liveness')]),
        ('kernel-run', [str(work / 'kernel-liveness')]),
        ('relay-c-object', clang + ['-I', str(source), '-c', str(relay / 'HelperC.c'), '-o', str(relay_object)]),
        ('production-owner-c-object', clang + ['-c', str(owner / 'OwnedBackend.c'), '-o', str(work / 'production-owner.o')]),
        ('production-helper-compile', swift + ['-import-objc-header', str(relay / 'HelperC.h'), '-I', str(source)]
         + [str(identity / name) for name in ('SSIAuthority.swift', 'SSIAppleBackend.swift', 'SSIFile.swift')]
         + [str(owner / name) for name in ('SupervisorLifecycle.swift', 'SystemBackend.swift')]
         + [str(relay / name) for name in ('RelayCodec.swift', 'SDKMailbox.swift', 'RelayMain.swift', 'main.swift')]
         + [str(relay_object), str(work / 'production-owner.o'), '-framework', 'Security', '-framework', 'CryptoKit', '-lproc', '-o', str(work / 'BettboxCoreSupervisor')]),
        ('relay-fixture-c-object', clang + ['-I', str(tests / 'Relay'), '-c', str(relay / 'HelperC.c'), '-o', str(fixture_object)]),
        ('relay-codec-compile', swift + ['-parse-as-library', '-import-objc-header', str(relay / 'HelperC.h'), '-I', str(tests / 'Relay'),
          str(relay / 'RelayCodec.swift'), str(tests / 'Relay/CodecMain.swift'), str(fixture_object), '-o', str(work / 'relay-codec')]),
        ('relay-codec-run', [str(work / 'relay-codec')]),
        ('relay-fake-compile', swift + ['-import-objc-header', str(relay / 'HelperC.h'), '-I', str(tests / 'Relay')]
         + [str(relay / name) for name in ('RelayCodec.swift', 'SDKMailbox.swift', 'RelayMain.swift')]
         + [str(tests / 'Relay/FakeRuntime.swift'), str(relay / 'main.swift'), str(fixture_object), '-o', str(work / 'relay-fake')]),
    ])
    for case in ('partial', 'credit', 'half-host', 'fullpipe-close'):
        result.append(('relay-' + case, ['python3', str(tests / 'Relay/relay_driver.py'), '--helper', str(work / 'relay-fake'), '--case', case]))
    for fault in ('late-initial', 'initial-reject', 'late-core', 'core-reject', 'counterfeit-credit', 'half-result'):
        result.append(('relay-' + fault, ['python3', str(tests / 'Relay/relay_driver.py'), '--helper', str(work / 'relay-fake'), '--case', 'fault', '--fake-fault', fault]))
    for case, fault in [('paused-hup', 'hup-while-paused'), ('pending-host-eof', 'fullpipe-result')]:
        result.append(('relay-' + case, ['python3', str(tests / 'Relay/relay_driver.py'), '--helper', str(work / 'relay-fake'), '--case', case, '--fake-fault', fault]))
    host_sources = [str(source / 'Host' / name) for name in ('HostSupervisorAuthority.swift', 'HostSupervisorProduction.swift')]
    result.extend([
        ('host-production-typecheck', swift + ['-typecheck', '-import-objc-header', str(source / 'Bridge.h')]
         + [str(identity / name) for name in ('SSIAuthority.swift', 'SSIAppleBackend.swift', 'SSIFile.swift')] + host_sources),
        ('host-fake-compile', swift + ['-parse-as-library', str(identity / 'SSIAuthority.swift'),
         str(source / 'Host/HostSupervisorAuthority.swift'), str(tests / 'HostSupervisorAuthorityTests.swift'), '-o', str(work / 'host-fake')]),
        ('host-fake-run', [str(work / 'host-fake')]),
    ])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--component', choices=('all', 'host'), default='all')
    parser.add_argument('--host-recheck-only', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    before = hashes(root)
    if not args.execute:
        print('计划：macOS12 arm64 SDK、生产helper编译、身份/owner/relay fake、公开true/sleep回收及内核消失分类。')
        return 0
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('此入口仅在本机 macOS arm64 执行')
    directory = root / '.test/three-platform-release'
    directory.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='supervisor-check-', dir=directory))
    receipt = {'scope': 'macos-supervisor-native-modules', 'status': 'failed',
               'source_hashes': before, 'steps': [], 'signed_guest_verified': False,
               'client_integrated': False, 'system_proxy_changed': False,
               'work_directory': str(work.relative_to(root))}
    try:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                      text=True, timeout=30).strip()
        receipt['sdk'] = Path(sdk).name
        planned = commands(root, work, sdk)
        if args.component == 'host':
            planned = [(name, argv) for name, argv in planned if name.startswith('host-')]
        if args.host_recheck_only:
            planned = [(name, argv + ['--recheck-only'] if name == 'host-fake-run' else argv) for name, argv in planned]
        receipt['component'] = args.component
        receipt['host_recheck_only'] = args.host_recheck_only
        for name, argv in planned:
            result = subprocess.run(argv, cwd=root, capture_output=True, timeout=180)
            (work / (name + '.log')).write_bytes(result.stdout + result.stderr)
            receipt['steps'].append({'step': name, 'exit_code': result.returncode})
            if result.returncode != 0:
                break
        receipt['source_unchanged'] = hashes(root) == before
        if len(receipt['steps']) == len(planned) and all(step['exit_code'] == 0 for step in receipt['steps']) and receipt['source_unchanged']:
            receipt['status'] = 'passed'
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        receipt['error_class'] = type(error).__name__
    finally:
        (work / 'execution.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        (directory / 'macos-supervisor-native.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'status': receipt['status'], 'receipt': str((work / 'execution.json').relative_to(root))}, ensure_ascii=False))
    return 0 if receipt['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
