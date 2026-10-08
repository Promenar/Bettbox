"""使用既有 Kotlin 缓存编译真实挂起模块与公开 Android 夹具。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "android/app/src/main/kotlin/com/appshub/bettbox/modules/SuspendModule.kt", *sorted((ROOT / "android/app/src/test/kotlin/com/appshub/bettbox/suspendfixture").glob("*.kt"))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-name", required=True)
    name = parser.parse_args().output_name
    if not name or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in name):
        raise ValueError("输出名称无效")
    cache = ROOT / ".test/android-build"
    compilers = sorted(cache.glob("gradle-home-*/wrapper/dists/gradle-8.14-all/*/gradle-8.14/lib/kotlin-compiler-embeddable-2.0.21.jar"))
    if not compilers:
        raise ValueError("已有工具缓存缺失")
    lib = compilers[0].parent
    compiler_jars = sorted(lib.glob("*.jar"))
    classpath = [lib / "kotlin-stdlib-2.0.21.jar"]
    inputs = list(dict.fromkeys(compiler_jars + classpath + SOURCES))
    for path in inputs:
        if not path.is_file() or any(p.is_symlink() for p in [path, *path.parents] if p != ROOT.parent):
            raise ValueError("工具输入路径无效")
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    parent = ROOT / ".test"
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError("输出父目录无效")
    output_dir = parent / name
    output_dir.mkdir(mode=0o700, exist_ok=False)
    java_home = subprocess.run(["/usr/libexec/java_home"], capture_output=True, text=True, timeout=10, check=True).stdout.strip()
    java = Path(java_home) / "bin/java"
    output = output_dir / "classes.jar"
    env = {"PATH": "/usr/bin:/bin", "HOME": str(Path.home())}
    commands = [
        [str(java), "-Xmx512m", "-cp", os.pathsep.join(map(str, compiler_jars)),
         "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect",
         "-jvm-target", "17", "-classpath", os.pathsep.join(map(str, classpath)),
         "-d", str(output), *map(str, SOURCES)],
        [str(java), "-cp", os.pathsep.join(map(str, [output, *classpath])),
         "com.appshub.bettbox.suspendfixture.AndroidSuspendModuleFixture"],
    ]
    result = None
    for index, command in enumerate(commands):
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
        if result.returncode:
            print(json.dumps({"stage": "compile" if index == 0 else "fixture", "exit_code": result.returncode, "fixture": json.loads(result.stdout) if index == 1 else None}))
            return 1
    if any(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != digest for p, digest in hashes.items()):
        raise ValueError("执行期间输入漂移")
    receipt = {
        "passed": True, "actual_Android": False, "fixture": json.loads(result.stdout),
        "sources_sha256": {str(p.relative_to(ROOT)): hashes[str(p.relative_to(ROOT))] for p in SOURCES},
        "compiler": "Kotlin2.0.21",
        "fixture_stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest(),
        "boundary": "真实生产挂起模块与公开平台桩；没有真实 Android 广播、JNI 或设备验收",
    }
    (output_dir / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": True, "receipt": str(output_dir.relative_to(ROOT) / "receipt.json")}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"failure_class": type(error).__name__}))
        raise SystemExit(1)
