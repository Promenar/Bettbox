#!/usr/bin/env python3
"""在已有 Xboard 镜像的无网络、只读临时容器内验证邀请业务。"""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ssh-target', required=True)
    parser.add_argument('--container', required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.ssh_target.startswith('-') or args.container.startswith('-'):
        parser.error('主机和容器名称不得是命令选项')
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-o', 'ConnectTimeout=10', args.ssh_target]
    inspected = subprocess.run(
        ssh + [shlex.join(['sudo', '-n', 'docker', 'inspect', args.container])],
        capture_output=True, timeout=30, check=True,
    )
    # inspect 的完整环境只在本地进程内解析，不回显或写入报告。
    source = json.loads(inspected.stdout)[0]
    mounts = json.dumps([entry['Destination'] for entry in source['Mounts']])
    command = [
        'sudo', '-n', 'docker', 'run', '--rm', '-i', '--network', 'none',
        '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '--pids-limit', '64', '--memory', '256m', '--cpus', '1',
        '--volumes-from', args.container + ':ro',
        '--tmpfs', '/tmp:rw,nosuid,nodev,size=64m', '-w', '/www',
        '-e', 'BETTBOX_VERIFY_ISOLATED_CONTAINER=1',
        '-e', 'BETTBOX_VERIFY_SOURCE_MOUNTS=' + mounts,
        '--entrypoint', 'php', source['Image'], '-d', 'display_errors=0',
        '/dev/stdin', '--run-in-memory',
    ]
    result = subprocess.run(
        ssh + [shlex.join(command)],
        input=Path(__file__).with_name('verify_xboard_invite.php').read_bytes(),
        capture_output=True, timeout=90,
    )
    report = json.loads(result.stdout)
    permitted = {
        'ok', 'mode', 'checks', 'public_commission_settings', 'stat_before',
        'stat_after', 'payment', 'mail_queue', 'source_database',
        'concurrent_settlement', 'captcha', 'stage', 'exception_class',
        'exception_file', 'exception_line',
    }
    if not isinstance(report, dict) or set(report) - permitted:
        raise ValueError('服务输出不符合白名单格式')
    report['source_image'] = source['Image']
    report['script_sha256'] = hashlib.sha256(
        Path(__file__).with_name('verify_xboard_invite.php').read_bytes()).hexdigest()
    rendered = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.report:
        args.report.write_text(rendered)
    print(rendered, end='')
    return 0 if result.returncode == 0 and report.get('ok') is True else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (subprocess.SubprocessError, ValueError, KeyError, TypeError, IndexError, OSError) as error:
        # 不回显远端 stderr、命令参数、响应体或异常消息。
        print(json.dumps({'ok': False, 'exception_class': type(error).__name__}))
        raise SystemExit(1)
