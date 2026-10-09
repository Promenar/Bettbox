#!/usr/bin/env python3
"""仅向 NoSLA 一次性禁网容器上传精确公开白名单，默认只输出计划。"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tarfile
import uuid

PUBLIC_INPUTS = (
    'app/Http/Kernel.php', 'app/Http/Controllers/Controller.php',
    'app/Helpers/ApiResponse.php', 'app/Helpers/ResponseEnum.php',
    'app/Exceptions/ApiException.php', 'app/Exceptions/BusinessException.php',
    'app/Exceptions/Handler.php', 'app/Contracts/PaymentInterface.php',
    'app/Http/Middleware/TrustProxies.php', 'app/Http/Middleware/CheckForMaintenanceMode.php',
    'app/Http/Middleware/TrimStrings.php', 'app/Http/Middleware/InitializePlugins.php',
    'app/Http/Middleware/ApplyRuntimeSettings.php', 'app/Http/Middleware/ForceJson.php',
    'app/Http/Middleware/Language.php', 'app/Models/User.php', 'app/Models/Plan.php',
    'app/Models/Order.php', 'app/Models/Payment.php', 'app/Models/Setting.php', 'app/Models/Plugin.php',
    'app/Models/CommissionLog.php', 'app/Models/TrafficResetLog.php',
    'app/Services/UserService.php', 'app/Services/PlanService.php',
    'app/Services/TrafficResetService.php', 'app/Services/PaymentService.php',
    'app/Services/Plugin/PluginManager.php', 'app/Services/Plugin/AbstractPlugin.php',
    'app/Services/Plugin/HookManager.php', 'app/Services/Plugin/InterceptResponseException.php',
    'app/Services/CouponService.php','app/Models/Coupon.php',
    'app/Support/Setting.php', 'app/Utils/Helper.php', 'app/Helpers/Functions.php',
)
CANDIDATE_INPUTS = (
    'server/patches/billing/overlay/app/Services/Billing/Atomic.php',
    'server/patches/billing/overlay/app/Services/Billing/Outbox.php',
    'server/patches/billing/overlay/app/Services/Billing/AtomicMigration.php',
    'server/patches/billing/overlay/app/Services/OrderService.php',
    'server/patches/billing/overlay/app/Jobs/OrderHandleJob.php',
    'server/patches/billing/overlay/app/Console/Commands/CheckCommission.php',
    'server/patches/billing/overlay/app/Console/Commands/CheckOrder.php',
    'server/patches/billing/overlay/app/Console/Commands/BillingMigrate.php',
    'server/patches/billing/overlay/app/Http/Controllers/V1/User/OrderController.php',
    'server/patches/billing/overlay/app/Http/Controllers/V1/Guest/PaymentController.php',
    'server/patches/billing/overlay/app/Http/Controllers/V2/Admin/OrderController.php',
    'server/patches/billing/overlay/database/migrations/billing_atomic_schema.sql',
    'server/patches/billing/overlay/database/migrations/2026_10_07_000001_add_billing_atomicity.php',
    'server/plugins/Fubei/config.json', 'server/plugins/Fubei/Plugin.php', 'server/plugins/Fubei/Amount.php',
    'server/plugins/Fubei/Client.php', 'server/plugins/Fubei/JsonAmount.php',
    'server/plugins/Fubei/Notification.php', 'server/plugins/Fubei/RawNotification.php',
    'server/plugins/Fubei/Signature.php', 'server/tests/billing/laravel_check.php',
    'server/tests/billing/laravel_support.php',
    'server/tests/billing/laravel_migration_check.php',
    'server/tests/billing/laravel_concurrency_check.php',
    'server/tests/billing/laravel_queue_check.php',
    'server/tests/billing/laravel_coupon_admin_check.php',
    'server/tests/billing/laravel_plugin_lifecycle_check.php',
)
IMAGE_SOURCE_CONTAINER = 'xboard-test-xboard-1'
DIGEST = re.compile(r'sha256:[a-f0-9]{64}\Z')
LABEL = re.compile(r'[A-Za-z0-9_.-]{1,120}\Z')


class RunnerFailure(RuntimeError):
    """只携带固定阶段类别，禁止传播远端原始正文。"""


def read_public(path):
    """逐层 O_NOFOLLOW 打开精确路径，不跟随父目录或文件链接。"""
    path = Path(os.path.abspath(path))
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        child = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
        with os.fdopen(child, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise RunnerFailure('input_not_regular')
            contents = stream.read(2 * 1024 * 1024 + 1)
            if len(contents) > 2 * 1024 * 1024:
                raise RunnerFailure('input_too_large')
            return contents
    finally:
        os.close(descriptor)


def freeze(root, public_root):
    buffer, hashes, inputs = io.BytesIO(), {}, []
    with tarfile.open(fileobj=buffer, mode='w') as archive:
        for prefix, base, names in [('public', public_root, PUBLIC_INPUTS), ('candidate', root, CANDIDATE_INPUTS)]:
            for name in names:
                path, member_name = base / name, prefix + '/' + name
                contents = read_public(path)
                hashes[member_name] = hashlib.sha256(contents).hexdigest()
                inputs.append((path, member_name))
                member = tarfile.TarInfo(member_name)
                member.size, member.mode, member.uid, member.gid = len(contents), 0o444, 0, 0
                archive.addfile(member, io.BytesIO(contents))
    if not unchanged(inputs, hashes):
        raise RunnerFailure('input_drift_during_freeze')
    return buffer.getvalue(), hashes, inputs


def unchanged(inputs, hashes):
    try:
        return all(hashlib.sha256(read_public(path)).hexdigest() == hashes[name] for path, name in inputs)
    except (OSError, RunnerFailure):
        return False


def ssh(command, *, data=None, timeout=90):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'NOSLA', command],
                          input=data, capture_output=True, timeout=timeout, check=True)


def quote(arguments):
    return ' '.join(shlex.quote(str(argument)) for argument in arguments)


def result_summary(raw, hashes):
    if len(raw) > 256 * 1024:
        raise RunnerFailure('fixture_output_too_large')
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError):
        raise RunnerFailure('fixture_output_invalid') from None
    if not isinstance(value, dict) or value.get('ok') is not True:
        raise RunnerFailure('fixture_assertion_failed')
    checks = value.get('checks')
    if not isinstance(checks, list) or not checks or len(checks) > 300 or any(not isinstance(item, str) or not LABEL.fullmatch(item) for item in checks):
        raise RunnerFailure('fixture_checks_invalid')
    required = {'negative_checkout_no_gateway_and_review_committed', 'real_open_and_traffic_reset',
                'plugin_real_path_resolved', 'plugin_install_disabled', 'plugin_global_switch_off',
                'plugin_catalog_real_code', 'plugin_enabled_real_instance', 'plugin_disabled_discovery_empty',
                'plugin_disabled_fresh_catalog_empty', 'plugin_uninstalled_row_removed',
                'repeat_commission_once', 'cancel_refund_once', 'outbox_at_least_once_consumer_idempotent',
                'historical_negative_processing_no_open', 'fubei_open_and_event_once', 'fixture_work_removed',
                'migration_actual_class', 'migration_history_preserved', 'migration_empty_down_preserves_history',
                'migration_up_after_empty_down', 'migration_foreign_keys_valid', 'migration_same_isolated_connection',
                'migration_evidence_attempt_retained', 'migration_evidence_review_retained',
                'migration_evidence_outbox_retained', 'migration_evidence_commission_retained',
                'migration_collision_order_id', 'migration_collision_level',
                'migration_unexpected_RuntimeException_propagated', 'migration_unexpected_UnexpectedValueException_propagated',
                'migration_migrator_exact_path', 'migration_migrator_batch_recorded',
                'migration_migrator_repeat_noop', 'migration_migrator_rollback_history_preserved',
                'migration_migrator_failure_atomic', 'migration_migrator_down_failure_atomic',
                'migration_repository_insert_failure_atomic','migration_repository_delete_failure_atomic',
                'migration_command_plan_no_write','migration_command_failure_fixed_and_atomic',
                'migration_command_real_rollback','migration_command_real_up','migration_command_repeat_noop',
                'migration_command_foreign_batch_retained','migration_command_financial_evidence_retained'}
    required.update({'parallel_reaped_deadline_no_cleanup_responsibility','parallel_create_one_order_balance_once','parallel_cancel_refund_once',
                     'parallel_notify_open_reset_event_once','parallel_cancel_paid_consistent_winner',
                     'parallel_commission_order_opened','parallel_commission_balance_log_once'})
    required.update({'parallel_tiers_level_2_balance_log_once', 'parallel_cycle_order_opened', 'parallel_free_repeat_no_extension', 'parallel_free_repeat_rejected', 'parallel_tiers_exact_log_count', 'parallel_cycle_member_0_unchanged', 'parallel_tiers_settlement_once', 'parallel_tiers_level_0_balance_log_once', 'parallel_tiers_level_1_balance_log_once', 'parallel_cycle_member_1_unchanged', 'parallel_free_open_reset_no_gateway', 'parallel_tiers_order_opened', 'parallel_cycle_rolls_back_logs_keeps_review', 'parallel_free_balance_fully_applied', 'parallel_cycle_member_2_unchanged'})
    required.update(name+'_overlap' for name in ['parallel_create','parallel_cancel','parallel_notify','parallel_cancel_paid','parallel_commission','parallel_free','parallel_tiers','parallel_cycle'])
    required.update({'queue_dedicated_database', 'queue_serialized_job_not_sync', 'parallel_queue_overlap', 'queue_paid_without_inline_open', 'queue_failure_business_transaction_rolled_back', 'queue_duplicate_retry_open_reset_event_once', 'queue_configuration_restored', 'queue_failed_job_released_for_retry', 'queue_empty_owned_table', 'queue_real_compensation_command', 'queue_workers_consumed_persistent_jobs', 'queue_duplicate_serialized_jobs', 'queue_processing_not_opened'})
    required.add('queue_two_pids_processed_target_once')
    required.update({'coupon_global_one_use_one_order', 'admin_paid_repeat_rejected', 'admin_paid_open_reset_once_no_gateway', 'coupon_empty_owned_table', 'coupon_user_1_consistent', 'coupon_retry_consumes_once', 'admin_paid_repeat_no_extension', 'parallel_coupon_overlap', 'coupon_winner_discount_balance_exact', 'parallel_admin_paid_overlap', 'coupon_dedicated_database', 'coupon_create_failure_restores_use_balance_order', 'coupon_user_0_consistent'})
    required.update('migration_collision_' + name for name in ['v2_billing_mutex','v2_payment_attempt','v2_billing_review','v2_billing_outbox'])
    if not required.issubset(checks) or value.get('environment_loaded') is not False or value.get('production_database_loaded') is not False:
        raise RunnerFailure('fixture_contract_incomplete')
    reported = value.get('source_hashes')
    expected = {'/fixture/source/' + name: digest for name, digest in hashes.items()}
    # fixture 自身由 runner 冻结；运行时 PHP 只报告被其显式载入的输入。
    expected.pop('/fixture/source/candidate/server/tests/billing/laravel_check.php')
    if not isinstance(reported, dict) or any(reported.get(path) != digest for path, digest in expected.items()):
        raise RunnerFailure('fixture_source_evidence_mismatch')
    return {'checks': checks, 'external_payment_verified': False, 'authentication_stubbed': True,
            'plugin_discovery_stubbed': True, 'gateway_transport_stubbed': True,
            'concurrency_verified_by_this_fixture': True}


def write_receipt(root, task_id, receipt):
    contents = json.dumps(receipt, ensure_ascii=False, indent=2) + '\n'
    root = Path(os.path.abspath(root))
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        # 从根目录逐层取得真实目录句柄，绝不重新走已经核验过的绝对父路径。
        for component in root.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        for component in ['.test', 'three-platform-release']:
            try:
                os.mkdir(component, mode=0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        # 目录即使随后被 rename，写入也绑定原句柄，不能跟随替换的新 symlink。
        filename = 'billing-laravel-receipt-' + task_id + '.json'
        fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=descriptor)
        with os.fdopen(fd, 'w') as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def execute(root, public_root):
    task_id = uuid.uuid4().hex
    remote, container = '/tmp/bettbox-laravel-' + task_id, 'bettbox-laravel-' + task_id
    receipt = {'scope': 'isolated-laravel-kernel-eloquent', 'task_id': task_id, 'status': 'failed',
               'stage': 'freeze', 'source_hashes': {}, 'source_unchanged': False,
               'business_database_mounted': False, 'source_environment_loaded': False,
               'network': 'none', 'cleanup_verified': False, 'image_source_container': IMAGE_SOURCE_CONTAINER}
    remote_attempted = False
    try:
        archive, hashes, inputs = freeze(root, public_root)
        receipt['source_hashes'] = hashes
        receipt['stage'] = 'image_identity'
        image = ssh(quote(['docker', 'inspect', '--format', '{{.Image}}', IMAGE_SOURCE_CONTAINER])).stdout.decode('ascii').strip()
        if not DIGEST.fullmatch(image):
            raise RunnerFailure('image_identity_invalid')
        receipt['image'] = image
        receipt['stage'] = 'upload'
        remote_attempted = True
        # mkdir 为排他操作；失败时不解包或启动容器。tar 来源仅为冻结的 regular 文件。
        ssh(' && '.join(['umask 077', quote(['mkdir', remote]),
                         quote(['printf', '%s', task_id]) + ' > ' + shlex.quote(remote + '/.owner'),
                         quote(['mkdir', remote + '/source', remote + '/work']),
                         quote(['tar', '-xf', '-', '-C', remote + '/source'])]), data=archive)
        receipt['stage'] = 'fixture'
        command = quote(['timeout', '--kill-after=5s', '240s', 'docker', 'run', '--name', container,
                         '--network', 'none', '--read-only', '--memory', '128m', '--memory-swap', '128m',
                         '--cpus', '0.5', '--pids-limit', '64', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                         '--label', 'bettbox.fixture=' + task_id,
                         '--mount', f'type=bind,source={remote}/source,target=/fixture/source,readonly',
                         '--mount', f'type=bind,source={remote}/work,target=/fixture/work',
                         '--env', 'BETTBOX_VERIFY_ISOLATED_CONTAINER=1', '--env', 'APP_ENV=testing',
                         '--entrypoint', 'php', image, '/fixture/source/candidate/server/tests/billing/laravel_check.php',
                         '--execute', '--vendor-root=/www/vendor', '--public-root=/fixture/source/public',
                         '--candidate-root=/fixture/source/candidate', '--work-root=/fixture/work'])
        output = ssh(command, timeout=265).stdout
        receipt['output_sha256'] = hashlib.sha256(output).hexdigest()
        receipt['result'] = result_summary(output, hashes)
        actual_image = ssh(quote(['docker', 'inspect', '--format', '{{.Image}}', container])).stdout.decode('ascii').strip()
        if actual_image != image:
            raise RunnerFailure('fixture_image_mismatch')
        receipt['executed_image_verified'] = True
        receipt['stage'] = 'source_recheck'
        receipt['source_unchanged'] = unchanged(inputs, hashes)
        if not receipt['source_unchanged']:
            raise RunnerFailure('source_drift')
        receipt['status'], receipt['stage'] = 'passed', 'complete'
    except (OSError, ValueError, subprocess.SubprocessError, RunnerFailure) as error:
        receipt['status'] = 'failed'
        # 不传播 stderr/stdout、异常 message、路径或命令参数。
        receipt['failure_category'] = str(error) if isinstance(error, RunnerFailure) else type(error).__name__
        if isinstance(error, subprocess.CalledProcessError) and receipt['stage'] == 'fixture':
            try:
                failure = json.loads(error.stdout)
                if isinstance(failure, dict) and failure.get('ok') is False and isinstance(failure.get('stage'), str) and LABEL.fullmatch(failure['stage']):
                    receipt['fixture_failure_stage'] = failure['stage']
                    witness = failure.get('http_witness')
                    if isinstance(witness, dict):
                        safe = {}
                        status = witness.get('http_status')
                        line = witness.get('exception_line')
                        if type(status) is int and 100 <= status <= 599:
                            safe['http_status'] = status
                        if type(line) is int and 1 <= line <= 1000000:
                            safe['exception_line'] = line
                        for count_name in ['gateway_count', 'review_count']:
                            count = witness.get(count_name)
                            if type(count) is int and 0 <= count <= 1000000:
                                safe[count_name] = count
                        for key, pattern in [('exception_class', r'[A-Za-z_][A-Za-z0-9_]*(?:\\[A-Za-z_][A-Za-z0-9_]*){0,16}'),
                                             ('exception_file', r'[A-Za-z0-9_-]{1,100}\.php'),
                                             ('missing_identifier', r'[A-Za-z_][A-Za-z0-9_.\\]{0,159}')]:
                            value = witness.get(key)
                            if isinstance(value, str) and re.fullmatch(pattern, value):
                                safe[key] = value
                        if safe:
                            receipt['fixture_http_witness'] = safe
            except (ValueError, TypeError, UnicodeError):
                pass
    finally:
        if remote_attempted:
            receipt['cleanup_verified'] = cleanup(remote, container, task_id)
        else:
            receipt['cleanup_verified'] = True
        if not receipt['cleanup_verified']:
            receipt.update(status='failed', failure_category='cleanup_unverified')
        write_receipt(root, task_id, receipt)
    return receipt


def cleanup(remote, container, task_id):
    try:
        # 先核对任务标签；同名其它容器绝不删除。删除结果不充当消失证据。
        owned = ssh(quote(['docker', 'container', 'ls', '-a', '--filter', f'name=^/{container}$',
                           '--format', '{{.Names}} {{.Label "bettbox.fixture"}}']))
        if owned.stdout.strip():
            if owned.stdout.strip() != (container + ' ' + task_id).encode():
                return False
            ssh(quote(['docker', 'rm', '-f', container]) + ' >/dev/null 2>&1')
        query = ssh(quote(['docker', 'container', 'ls', '-a', '--filter', f'name=^/{container}$', '--format', '{{.Names}}']))
        if query.stdout.strip():
            return False
        # mkdir 或上传失败也只清理带本任务标记的目录；已有同名目录保留并报告失败。
        absent = quote(['test', '!', '-e', remote]) + ' && ' + quote(['test', '!', '-L', remote])
        owned_directory = ' && '.join([quote(['test', '!', '-L', remote]), quote(['test', '-f', remote + '/.owner']),
                                      quote(['test', '!', '-L', remote + '/.owner']),
                                      '[ "$(cat ' + shlex.quote(remote + '/.owner') + ')" = ' + shlex.quote(task_id) + ' ]',
                                      quote(['rm', '-rf', '--', remote])])
        ssh('( ' + absent + ' ) || ( ' + owned_directory + ' )')
        ssh(quote(['test', '!', '-e', remote]) + ' && ' + quote(['test', '!', '-L', remote]))
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--root', type=Path, default=Path(__file__).absolute().parents[3])
    parser.add_argument('--public-root', type=Path)
    args = parser.parse_args(argv)
    if not args.execute:
        print(json.dumps({'mode': 'plan', 'network': 'none', 'memory_mib': 128, 'cpus': 0.5, 'pids': 64,
                          'public_files': len(PUBLIC_INPUTS), 'candidate_files': len(CANDIDATE_INPUTS),
                          'vendor': '现有镜像 /www/vendor；缺失则失败，不安装'}, ensure_ascii=False))
        return 0
    root = Path(os.path.abspath(args.root))
    public_root = Path(os.path.abspath(args.public_root or root / '.test/billing-laravel-public-source'))
    receipt = execute(root, public_root)
    print(json.dumps(receipt, ensure_ascii=False))
    return 0 if receipt['status'] == 'passed' else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit('Laravel 隔离执行器失败；未回显原始错误正文') from None
