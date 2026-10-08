#!/usr/bin/env python3
"""用已有任务缓存编译并运行生产 Kotlin FD 租约的公开 JVM 夹具。"""
import hashlib
import json
from pathlib import Path
import subprocess
import os

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / 'android/core/src/main/java/com/appshub/bettbox/core/TunFDLease.kt',
    ROOT / 'android/core/src/test/kotlin/com/appshub/bettbox/core/TunFDLeaseFixture.kt',
]

def main():
    cache = ROOT / '.test/android-build'
    # Gradle 8.14 自带一致的 Kotlin 编译器；该夹具不替代 Android 2.1.0 工程编译。
    compiler = sorted(cache.glob('gradle-home-*/wrapper/dists/gradle-8.14-all/*/gradle-8.14/lib/kotlin-compiler-embeddable-2.0.21.jar'))
    if not compiler:
        raise ValueError('compiler_cache_missing')
    lib = compiler[0].parent
    jars = sorted(lib.glob('*.jar'))
    annotation = sorted(cache.glob('gradle-home-*/caches/modules-2/files-2.1/androidx.annotation/annotation-jvm/1.9.1/*/annotation-jvm-1.9.1.jar'))
    if not annotation:
        raise ValueError('annotation_cache_missing')
    classpath = [lib / 'kotlin-stdlib-2.0.21.jar', annotation[0]]
    for p in jars + classpath + SOURCES:
        if not p.is_file() or p.is_symlink():
            raise ValueError('unsafe_input_path')
    inputs = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in jars + classpath + SOURCES}
    java_home = Path(subprocess.check_output(['/usr/libexec/java_home'], text=True).strip())
    java = java_home / 'bin/java'
    output = ROOT / '.test/android-tun-lease/classes.jar'
    output.parent.mkdir(parents=True, exist_ok=True)
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(Path.home())}
    commands = [
        [str(java), '-Xmx512m', '-cp', os.pathsep.join(map(str, jars)),
         'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
         '-jvm-target', '17', '-classpath', os.pathsep.join(map(str, classpath)),
         '-d', str(output), *map(str, SOURCES)],
        [str(java), '-cp', os.pathsep.join(map(str, [output, *classpath])),
         'com.appshub.bettbox.core.TunFDLeaseFixtureKt'],
    ]
    for command in commands:
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
        if result.returncode:
            print(json.dumps({'stage': 'compile_or_fixture', 'exit_code': result.returncode,
                              'public_diagnostic': result.stderr[:4000]}, ensure_ascii=False))
            return 1
    for relative, digest in inputs.items():
        if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != digest:
            raise ValueError('source_drift')
    fixture = json.loads(result.stdout)
    if fixture != {'lease_cases_passed': 6, 'actual_FD_used': False}:
        raise ValueError('fixture_receipt_invalid')
    receipt = {**fixture, 'compiler': 'Gradle8.14 Kotlin2.0.21', 'exit_confirmed': True,
               'production_source_sha256': {str(p.relative_to(ROOT)): inputs[str(p.relative_to(ROOT))] for p in SOURCES},
               'boundary': '生产租约的JVM行为；不证明Android Kotlin2.1.0编译、JNI或实际FD。'}
    (output.parent / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(receipt, ensure_ascii=False))
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'failure_class': type(error).__name__}))
        raise SystemExit(1)
