#!/usr/bin/env python3
"""在 NoSLA 已有镜像中隔离运行公开付呗 fixture，不挂载业务库或凭据。"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import tarfile
import uuid


def ssh(command, *, data=None, timeout=90):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                           "NOSLA", command], input=data, capture_output=True,
                          timeout=timeout, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    paths = sorted((root / "server/plugins/Fubei").glob("*.php"))
    paths += [root / "server/plugins/Fubei/config.json"]
    paths += [root / "server/tests/fubei" / n for n in ("run.php", "adapter.php", "fixture.json")]
    if not args.execute:
        print("计划：仅公开 PHP fixture，现有 Xboard 镜像，禁网/只读/64MiB，无业务挂载。")
        return
    buffer = io.BytesIO()
    hashes = {}
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for path in paths:
            if path.is_symlink() or not path.is_file():
                raise ValueError("fixture 输入缺失或为符号链接")
            contents = path.read_bytes()
            name = str(path.relative_to(root))
            hashes[name] = hashlib.sha256(contents).hexdigest()
            member = tarfile.TarInfo(name)
            member.size, member.mode = len(contents), 0o444
            archive.addfile(member, io.BytesIO(contents))
    image = ssh("docker inspect --format '{{.Image}}' xboard-test-xboard-1").stdout.decode().strip()
    if not image.startswith("sha256:") or len(image) != 71:
        raise ValueError("未获得当前运行镜像的明确身份")
    remote = "/tmp/bettbox-fubei-fixture-" + uuid.uuid4().hex
    receipt = {"scope": "isolated-public-fubei-fixture", "image": image,
               "source_hashes": hashes, "business_database_mounted": False,
               "network": "none", "status": "failed"}
    try:
        ssh(f"umask 077; mkdir {shlex.quote(remote)}; tar -xf - -C {shlex.quote(remote)}",
            data=buffer.getvalue())
        command = " ".join(shlex.quote(x) for x in [
            "docker", "run", "--rm", "--network", "none", "--read-only",
            "--memory", "64m", "--cpus", "0.5", "--pids-limit", "32",
            "--mount", f"type=bind,source={remote},target=/fixture,readonly",
            "--entrypoint", "php", image, "/fixture/server/tests/fubei/run.php"])
        result = ssh(command)
        # 此容器只包含本地公开虚构 fixture，未加载 Laravel 或服务器配置。
        output = result.stdout.decode()
        print(output, end="")
        receipt.update(status="passed", output_sha256=hashlib.sha256(result.stdout).hexdigest())
    finally:
        ssh(f"rm -rf -- {shlex.quote(remote)}")
        folder = root / ".test/three-platform-release"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "fubei-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"隔离 fixture 失败：命令退出码 {error.returncode}，未回显原始服务器错误")
