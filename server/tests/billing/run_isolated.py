#!/usr/bin/env python3
"""用 NoSLA 现有 PHP 镜像验证一次性 SQLite 并发，不访问业务数据库。"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import tarfile
import uuid

PUBLIC_INPUTS = (
    "server/patches/billing/overlay/app/Services/Billing/Atomic.php",
    "server/patches/billing/overlay/app/Services/Billing/Outbox.php",
    "server/patches/billing/overlay/app/Http/Controllers/V1/User/OrderController.php",
    "server/patches/billing/overlay/database/migrations/billing_atomic_schema.sql",
    "server/tests/billing/PdoConnection.php", "server/tests/billing/plugin_worker.php",
    "server/tests/billing/worker.php", "server/tests/billing/run.py", "server/tests/billing/checkout_worker.php",
    "server/plugins/Fubei/Amount.php", "server/plugins/Fubei/Client.php",
    "server/plugins/Fubei/JsonAmount.php", "server/plugins/Fubei/Notification.php",
    "server/plugins/Fubei/Plugin.php", "server/plugins/Fubei/RawNotification.php",
    "server/plugins/Fubei/Signature.php", "server/plugins/Fubei/config.json",
)


def safe_file(path, root):
    return path.is_file() and not path.is_symlink() and all(
        not parent.is_symlink() for parent in path.parents if parent.is_relative_to(root)
    )


def ssh(command, *, data=None, timeout=90):
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "NOSLA", command],
        input=data, capture_output=True, timeout=timeout, check=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if not args.execute:
        print("计划：公开候选源码、128MiB 禁网 PHP 容器、一次性 SQLite，多进程事务验收；不挂载业务库或凭据。")
        return
    root = Path(__file__).resolve().parents[3]
    paths = [root / name for name in PUBLIC_INPUTS]
    hashes = {}
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for path in paths:
            if not safe_file(path, root):
                raise ValueError("公开 fixture 输入缺失或路径含符号链接")
            contents = path.read_bytes()
            name = str(path.relative_to(root))
            hashes[name] = hashlib.sha256(contents).hexdigest()
            member = tarfile.TarInfo(name)
            member.size, member.mode = len(contents), 0o444
            archive.addfile(member, io.BytesIO(contents))
    image = ssh("docker inspect --format '{{.Image}}' xboard-test-xboard-1").stdout.decode().strip()
    if not image.startswith("sha256:") or len(image) != 71 or any(c not in "0123456789abcdef" for c in image[7:]):
        raise ValueError("当前 PHP 镜像身份无效")
    task_id = uuid.uuid4().hex
    remote = "/tmp/bettbox-billing-fixture-" + task_id
    container = "bettbox-billing-fixture-" + task_id
    receipt = {"scope": "isolated-php-sqlite-concurrency", "image": image,
               "source_hashes": hashes, "business_database_mounted": False,
               "network": "none", "status": "failed", "cleanup_verified": False}
    try:
        ssh(f"umask 077; mkdir {shlex.quote(remote)}; mkdir {shlex.quote(remote + '/source')} {shlex.quote(remote + '/work')}; tar -xf - -C {shlex.quote(remote + '/source')}", data=buffer.getvalue())
        command = " ".join(shlex.quote(x) for x in [
            "docker", "run", "--detach", "--name", container, "--network", "none",
            "--read-only", "--memory", "128m", "--cpus", "0.5", "--pids-limit", "64",
            "--mount", f"type=bind,source={remote}/source,target={remote}/source,readonly",
            "--mount", f"type=bind,source={remote}/work,target={remote}/work",
            "--entrypoint", "/bin/sh", image, "-c", "sleep 600",
        ])
        ssh(command)
        wrapper = "#!/bin/sh\nexec docker exec " + shlex.quote(container) + ' php "$@"\n'
        ssh(f"cat > {shlex.quote(remote + '/php')}; chmod 700 {shlex.quote(remote + '/php')}", data=wrapper.encode())
        command = " ".join(shlex.quote(x) for x in [
            "env", f"TMPDIR={remote}/work", "timeout", "--kill-after=5s", "240s", "python3",
            f"{remote}/source/server/tests/billing/run.py", "--php", f"{remote}/php",
        ])
        result = ssh(command, timeout=260)
        # 仅公开虚构 fixture 的输出；容器没有业务配置、环境变量或生产库。
        print(result.stdout.decode(), end="")
        unchanged = all(safe_file(path, root) and
                        hashlib.sha256(path.read_bytes()).hexdigest() == hashes[str(path.relative_to(root))]
                        for path in paths)
        receipt.update(status="passed" if unchanged else "failed", source_unchanged=unchanged,
                       output_sha256=hashlib.sha256(result.stdout).hexdigest())
        if not unchanged:
            raise ValueError("fixture 执行期间源码变化，拒绝复用验收结果")
    finally:
        try:
            ssh(f"docker rm -f {shlex.quote(container)} >/dev/null 2>&1; rm -rf -- {shlex.quote(remote)}")
            ssh(f"test ! -e {shlex.quote(remote)}")
            query = ssh(" ".join(shlex.quote(x) for x in ["docker", "container", "ls", "-a", "--filter", f"name=^/{container}$", "--format", "{{.Names}}"] ))
            if query.stdout.strip():
                raise RuntimeError("隔离容器仍存在")
            receipt["cleanup_verified"] = True
        except (OSError, subprocess.SubprocessError, RuntimeError):
            receipt.update(status="failed", cleanup_verified=False)
        folder = root / ".test/three-platform-release"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "billing-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        if not receipt["cleanup_verified"]:
            raise RuntimeError("隔离 fixture 清理未核实，验收失败；请检查任务标识对应临时资源")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"隔离 SQLite fixture 失败：退出码 {error.returncode}；未回显服务器错误正文")
