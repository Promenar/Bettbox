#!/usr/bin/env python3
"""用已有构建缓存执行生产 VPN 工作门禁的公开协程夹具。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / 'android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnLifecycle.kt',
    ROOT / 'android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnWorkGate.kt',
    ROOT / 'android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnIntentController.kt',
    ROOT / 'android/app/src/main/kotlin/com/appshub/bettbox/plugins/SmartResumeAwaiter.kt',
    ROOT / 'android/app/src/main/kotlin/com/appshub/bettbox/services/ForegroundPublication.kt',
    ROOT / 'android/app/src/test/kotlin/com/appshub/bettbox/plugins/VpnWorkGateFixture.kt',
    ROOT / 'android/app/src/test/kotlin/com/appshub/bettbox/plugins/VpnLifecycleFixture.kt',
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-name", default="android-vpn-work-gate")
    name = parser.parse_args().output_name
    if not name or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in name):
        raise ValueError("输出名称无效")
    cache = ROOT / '.test/android-build'
    compiler = sorted(cache.glob('gradle-home-*/wrapper/dists/gradle-8.14-all/*/gradle-8.14/lib/kotlin-compiler-embeddable-2.0.21.jar'))
    coroutine = sorted(cache.glob('gradle-home-*/caches/modules-2/files-2.1/org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.9.0/*/kotlinx-coroutines-core-jvm-1.9.0.jar'))
    if not compiler or not coroutine:
        raise ValueError('compiler_or_coroutine_cache_missing')
    lib = compiler[0].parent
    jars = sorted(lib.glob('*.jar'))
    classpath = [lib / 'kotlin-stdlib-2.0.21.jar', coroutine[0]]
    paths = list(dict.fromkeys(jars + classpath + SOURCES))
    if any(not p.is_file() or p.is_symlink() for p in paths):
        raise ValueError('unsafe_input_path')
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    java = Path(subprocess.check_output(['/usr/libexec/java_home'], text=True).strip()) / 'bin/java'
    output = ROOT / '.test' / name / 'classes.jar'
    output.parent.mkdir(parents=True, exist_ok=True)
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(Path.home())}
    commands = [
        [str(java), '-Xmx512m', '-cp', os.pathsep.join(map(str, jars)),
         'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
         '-jvm-target', '17', '-classpath', os.pathsep.join(map(str, classpath)),
         '-d', str(output), *map(str, SOURCES)],
        [str(java), '-cp', os.pathsep.join(map(str, [output, *classpath])),
         'com.appshub.bettbox.plugins.VpnWorkGateFixture'],
        [str(java), '-cp', os.pathsep.join(map(str, [output, *classpath])),
         'com.appshub.bettbox.plugins.VpnLifecycleFixture'],
    ]
    for index, command in enumerate(commands):
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
        if result.returncode:
            print(json.dumps({'stage': 'compile' if index == 0 else 'fixture',
                              'exit_code': result.returncode,
                              'public_diagnostic': result.stderr[:4000]}, ensure_ascii=False))
            return 1
    if any(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest for name, digest in hashes.items()):
        raise ValueError('source_drift')
    receipt = {'fixture_exit': 0, 'fixture_entrypoints': 2, 'actual_Android': False,
               'compiler': 'Gradle8.14 Kotlin2.0.21', 'coroutine': '1.9.0',
               'production_sources': {str(p.relative_to(ROOT)): hashes[str(p.relative_to(ROOT))] for p in SOURCES},
               'boundary': '实际生产协程门禁，公开异步屏障；不替代Service/Binder/JNI或真实FD设备验证。'}
    (output.parent / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(receipt, ensure_ascii=False))
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'failure_class': type(error).__name__}))
        raise SystemExit(1)
