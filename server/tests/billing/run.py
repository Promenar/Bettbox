#!/usr/bin/env python3
"""在一次性 SQLite 文件上启动独立 PHP 进程，验证候选 Atomic 的事务不变量。"""
import argparse
import hashlib
import shutil
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
SCHEMA = HERE.parent.parent / 'patches/billing/overlay/database/migrations/billing_atomic_schema.sql'


def initialize(path):
    db = sqlite3.connect(path)
    # 只包含实际 Xboard 迁移中的业务字段；测试 opened 为可观察的开通副作用计数。
    db.executescript('''
    CREATE TABLE test_gateway_call(id INTEGER PRIMARY KEY,trade_no TEXT NOT NULL,amount INTEGER NOT NULL);
    CREATE TABLE test_consumer(event_id TEXT PRIMARY KEY,order_id INTEGER NOT NULL);
    CREATE TABLE v2_user(id INTEGER PRIMARY KEY,invite_user_id INTEGER NULL,balance INTEGER NOT NULL DEFAULT 0,commission_balance INTEGER NOT NULL DEFAULT 0,updated_at INTEGER NOT NULL DEFAULT 0,opened INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE v2_payment(id INTEGER PRIMARY KEY,payment TEXT,enable INTEGER,uuid TEXT,handling_fee_fixed INTEGER DEFAULT 0,handling_fee_percent INTEGER DEFAULT 0);
    CREATE TABLE v2_order(id INTEGER PRIMARY KEY,user_id INTEGER NOT NULL,invite_user_id INTEGER NULL,payment_id INTEGER NULL,trade_no TEXT NOT NULL UNIQUE,callback_no TEXT NULL,total_amount INTEGER NOT NULL,handling_amount INTEGER NULL,balance_amount INTEGER NULL,status INTEGER NOT NULL,commission_status INTEGER NOT NULL DEFAULT 0,commission_balance INTEGER NOT NULL DEFAULT 0,actual_commission_balance INTEGER NULL,paid_at INTEGER NULL,updated_at INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE v2_commission_log(id INTEGER PRIMARY KEY,invite_user_id INTEGER NOT NULL,user_id INTEGER NOT NULL,trade_no TEXT NOT NULL,order_amount INTEGER NOT NULL,get_amount INTEGER NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
    INSERT INTO v2_user(id,invite_user_id) VALUES(1,2),(2,NULL);
    INSERT INTO v2_payment(id,payment,enable,uuid) VALUES(5,'Fubei',1,'PUBLIC-UUID');
    INSERT INTO v2_order(id,user_id,invite_user_id,payment_id,trade_no,total_amount,balance_amount,status,commission_balance) VALUES(1,1,2,5,'ORDER1',1000,100,0,100);
    ''')
    db.executescript(SCHEMA.read_text())
    db.commit()
    return db


def launch(php, path, operations, directory, suffix, ids=None):
    barrier = directory / ('barrier-' + suffix)
    processes = [subprocess.Popen([php, str(HERE / ('plugin_worker.php' if operation.startswith('plugin_') else ('checkout_worker.php' if operation.startswith('checkout_') else 'worker.php'))), str(path), operation, str(barrier), str(ids[i] if ids else 1)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for i, operation in enumerate(operations)]
    deadline = time.monotonic() + 15
    while len(list(directory.glob(barrier.name + '.ready.*'))) != len(processes):
        if time.monotonic() > deadline or any(process.poll() is not None for process in processes):
            for process in processes:
                if process.poll() is None: process.kill()
            raise RuntimeError('PHP 进程未成功到达 SQLite 并发屏障，请检查隔离 PHP 和 pdo_sqlite')
        time.sleep(0.01)
    barrier.touch()
    failures = []
    for process in processes:
        try:
            stdout, stderr = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            failures.append('独立进程超时')
        if process.returncode:
            failures.append(stdout + stderr)
    if failures:
        raise RuntimeError('\n'.join(failures))


def scalar(db, sql):
    return db.execute(sql).fetchone()[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--php', default=shutil.which('php'))
    args = parser.parse_args()
    if not args.php:
        raise RuntimeError('未发现 PHP；请显式提供带 pdo_sqlite 的隔离 PHP，不自动安装')
    with tempfile.TemporaryDirectory(prefix='billing-sqlite-') as temporary:
        directory = Path(temporary)
        path = directory / 'test.sqlite'
        db = initialize(path)
        launch(args.php,path,['paid']*6,directory,'paid')
        assert scalar(db,'SELECT status FROM v2_order WHERE id=1') == 1
        launch(args.php,path,['open']*6,directory,'open')
        assert scalar(db,'SELECT opened FROM v2_user WHERE id=1') == 1
        assert scalar(db,'SELECT status FROM v2_order WHERE id=1') == 3
        db.execute('UPDATE v2_order SET commission_status=1 WHERE id=1'); db.commit()
        launch(args.php,path,['commission']*6,directory,'commission')
        assert scalar(db,'SELECT commission_balance FROM v2_user WHERE id=2') == 100
        assert scalar(db,'SELECT count(*) FROM v2_commission_log') == 1
        launch(args.php,path,['rollback'],directory,'rollback')
        assert scalar(db,'SELECT balance FROM v2_user WHERE id=1') == 0

        # 取消先完成：多次取消只退款一次，迟到付款保留人工核对证据。
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,balance_amount,status) VALUES(2,1,5,'ORDER2',1000,100,0)"); db.commit()
        launch(args.php,path,['cancel']*6,directory,'cancel',[2]*6)
        assert scalar(db,'SELECT balance FROM v2_user WHERE id=1') == 100
        launch(args.php,path,['paid']*3,directory,'late',[2]*3)
        assert scalar(db,'SELECT status FROM v2_order WHERE id=2') == 2
        assert scalar(db,"SELECT count(*) FROM v2_billing_review WHERE order_id=2 AND category='cancelled_payment'") == 1

        # 真正竞争：pending 到账与取消二者只能有一个获胜。
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,balance_amount,status) VALUES(3,1,5,'ORDER3',1000,100,0)"); db.commit()
        before = scalar(db,'SELECT balance FROM v2_user WHERE id=1')
        launch(args.php,path,['paid','cancel']*4,directory,'race',[3]*8)
        state = scalar(db,'SELECT status FROM v2_order WHERE id=3')
        assert state in (1,2)
        assert scalar(db,'SELECT balance FROM v2_user WHERE id=1') == before + (100 if state == 2 else 0)

        # 不可变快照复用、并发同流水结算与数据库约束。
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(4,1,5,'ORDER4',1000,0)"); db.commit()
        launch(args.php,path,['attempt']*6,directory,'attempt',[4]*6)
        assert scalar(db,'SELECT count(*) FROM v2_payment_attempt WHERE order_id=4') == 1
        assert scalar(db,'SELECT length(external_no) FROM v2_payment_attempt WHERE order_id=4') == 32
        launch(args.php,path,['settle']*6,directory,'settle',[4]*6)
        assert scalar(db,'SELECT status FROM v2_order WHERE id=4') == 1
        try:
            db.execute('UPDATE v2_payment_attempt SET expected_cents=999 WHERE order_id=4')
            raise AssertionError('不可变快照允许修改')
        except sqlite3.IntegrityError:
            db.rollback()
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(5,1,5,'ORDER5',1000,0)"); db.commit()
        launch(args.php,path,['attempt'],directory,'attempt2',[5])
        try:
            db.execute("UPDATE v2_payment_attempt SET provider_no='PROVIDER_FIXTURE' WHERE order_id=5")
            raise AssertionError('平台流水允许跨订单重复')
        except sqlite3.IntegrityError:
            db.rollback()

        # 循环邀请：发生在同一事务中的已插日志和余额均须回滚。
        db.execute('UPDATE v2_user SET invite_user_id=2 WHERE id=2')
        db.execute("INSERT INTO v2_order(id,user_id,invite_user_id,payment_id,trade_no,total_amount,status,commission_status,commission_balance) VALUES(6,1,2,5,'ORDER6',1000,3,1,100)"); db.commit()
        before = scalar(db,'SELECT commission_balance FROM v2_user WHERE id=2')
        launch(args.php,path,['cycle'],directory,'cycle',[6])
        assert scalar(db,'SELECT commission_balance FROM v2_user WHERE id=2') == before
        assert scalar(db,'SELECT count(*) FROM v2_commission_log WHERE order_id=6') == 0
        assert scalar(db,'SELECT count(*) FROM v2_billing_review WHERE order_id=6') == 1
        assert scalar(db,'SELECT commission_status FROM v2_order WHERE id=6') == 1
        # 购买者参与三层循环：1→2→3→1；拒绝把购买者变成第三层受益人。
        db.execute('INSERT INTO v2_user(id,invite_user_id) VALUES(3,1)')
        db.execute('UPDATE v2_user SET invite_user_id=3 WHERE id=2')
        db.execute("INSERT INTO v2_order(id,user_id,invite_user_id,payment_id,trade_no,total_amount,status,commission_status,commission_balance) VALUES(8,1,2,5,'ORDER8',1000,3,1,100),(9,1,1,5,'ORDER9',1000,3,1,100)")
        db.commit()
        balances = db.execute('SELECT id,commission_balance FROM v2_user ORDER BY id').fetchall()
        launch(args.php,path,['cycle','cycle'],directory,'purchasercycle',[8,9])
        assert db.execute('SELECT id,commission_balance FROM v2_user ORDER BY id').fetchall() == balances
        assert scalar(db,'SELECT count(*) FROM v2_commission_log WHERE order_id IN (8,9)') == 0
        assert scalar(db,'SELECT count(*) FROM v2_billing_review WHERE order_id IN (8,9)') == 2
        assert scalar(db,'SELECT count(*) FROM v2_order WHERE id IN (8,9) AND commission_status=1') == 2

        # 首次开通失败不丢失事件；恢复完成后才能交付。
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(10,1,5,'ORDER10',1000,0)"); db.commit()
        launch(args.php,path,['paid'],directory,'outboxpaid',[10])
        assert scalar(db,'SELECT count(*) FROM v2_billing_outbox WHERE order_id=10 AND delivered_at IS NULL') == 1
        opened=scalar(db,'SELECT opened FROM v2_user WHERE id=1')
        launch(args.php,path,['open_fail','deliver'],directory,'outboxfail',[10,10])
        assert scalar(db,'SELECT status FROM v2_order WHERE id=10') == 1
        assert scalar(db,'SELECT opened FROM v2_user WHERE id=1') == opened
        assert scalar(db,'SELECT count(*) FROM test_consumer WHERE order_id=10') == 0
        launch(args.php,path,['open_recover']*6,directory,'outboxrecover',[10]*6)
        assert scalar(db,'SELECT opened FROM v2_user WHERE id=1') == opened+1
        launch(args.php,path,['deliver_crash'],directory,'outboxcrash',[10])
        assert scalar(db,'SELECT count(*) FROM test_consumer WHERE order_id=10') == 1
        assert scalar(db,'SELECT count(*) FROM v2_billing_outbox WHERE order_id=10 AND delivered_at IS NULL AND lease_token IS NOT NULL') == 1
        # 测试时钟前移租约，无需等待真实60秒；仅修改一次性数据库。
        db.execute('UPDATE v2_billing_outbox SET lease_until=0 WHERE order_id=10'); db.commit()
        launch(args.php,path,['deliver']*6,directory,'outboxrepeat',[10]*6)
        assert scalar(db,'SELECT count(*) FROM test_consumer WHERE order_id=10') == 1
        assert scalar(db,'SELECT count(*) FROM v2_billing_outbox WHERE order_id=10 AND delivered_at IS NOT NULL AND attempts=2') == 1

        internal = 'INTERNAL' + '0' * 28
        db.execute('INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(7,1,5,?,1000,0)',[internal]); db.commit()
        launch(args.php,path,['plugin_pay']*6,directory,'pluginpay',[7]*6)
        assert scalar(db,'SELECT count(*) FROM v2_payment_attempt WHERE order_id=7') == 1
        launch(args.php,path,['plugin_pay_rotated'],directory,'pluginrotatedpay',[7])
        assert scalar(db,"SELECT count(*) FROM v2_payment_attempt WHERE order_id=7 AND secret_ref='public_fixture' AND merchant_id=123 AND store_id=456") == 1
        launch(args.php,path,['plugin_notify_rotated']*6,directory,'pluginnotify',[7]*6)
        assert scalar(db,'SELECT status FROM v2_order WHERE id=7') == 1
        assert scalar(db,"SELECT count(*) FROM v2_payment_attempt WHERE order_id=7 AND provider_no='PLUGIN_PROVIDER' AND status=1") == 1
        # 负数订单不能通过可信免费入口；数据库当前值参与判断。
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(11,1,5,'NEGATIVE11',-1,0)"); db.commit()
        launch(args.php,path,['free_negative'],directory,'negativefree',[11])
        assert scalar(db,'SELECT status FROM v2_order WHERE id=11') == 0
        assert scalar(db,'SELECT count(*) FROM v2_billing_outbox WHERE order_id=11') == 0
        # 历史负数 PROCESSING 保留财务字段，不调用开通动作；证据必须提交而非随异常回滚。
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,handling_amount,status,callback_no,paid_at) VALUES(12,1,5,'NEGATIVE12',-100,200,0,NULL,NULL),(13,1,5,'NEGATIVE13',100,-1,0,NULL,NULL),(14,1,5,'NEGATIVE14',-100,200,1,'HISTORICAL14',123),(15,1,5,'NEGATIVE15',100,-1,1,'HISTORICAL15',123)")
        for order_id in [14,15]:
            event_id=hashlib.sha256(('payment.notify.success:'+str(order_id)).encode()).hexdigest()
            db.execute('INSERT INTO v2_billing_outbox(event_id,order_id,event_type,created_at) VALUES(?,?,?,123)',[event_id,order_id,'payment.notify.success'])
        db.commit()
        financial_before=db.execute('SELECT * FROM v2_order WHERE id IN (12,13,14,15) ORDER BY id').fetchall()
        users_before=db.execute('SELECT * FROM v2_user ORDER BY id').fetchall()
        logs_before=scalar(db,'SELECT count(*) FROM v2_commission_log')
        launch(args.php,path,['negative_paid_sources']*6,directory,'negativepaid',[12,13,14,15,12,13])
        launch(args.php,path,['negative_attempt']*2,directory,'negativeattempt',[12,13])
        assert scalar(db,'SELECT count(*) FROM v2_payment_attempt WHERE order_id IN (12,13)') == 0
        launch(args.php,path,['negative_open']*6,directory,'negativeopen',[14,15,14,15,14,15])
        launch(args.php,path,['deliver']*4,directory,'negativedeliver',[14,15,14,15])
        assert db.execute('SELECT * FROM v2_order WHERE id IN (12,13,14,15) ORDER BY id').fetchall() == financial_before
        assert db.execute('SELECT * FROM v2_user ORDER BY id').fetchall() == users_before
        assert scalar(db,'SELECT count(*) FROM v2_commission_log') == logs_before
        assert scalar(db,"SELECT count(*) FROM v2_billing_review WHERE order_id IN (12,13,14,15) AND category='negative_order_amount'") == 4
        assert scalar(db,'SELECT count(*) FROM v2_billing_outbox WHERE order_id IN (12,13)') == 0
        assert scalar(db,'SELECT count(*) FROM v2_billing_outbox WHERE order_id IN (14,15) AND delivered_at IS NULL AND attempts=0') == 2
        assert scalar(db,'SELECT count(*) FROM test_consumer WHERE order_id IN (14,15)') == 0
        # 快照创建后原始金额变负：已验签流水保留，尝试进入人工核对，不开通。
        db.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(16,1,5,'NEGATIVE16',1000,0)"); db.commit()
        launch(args.php,path,['attempt'],directory,'negativebefore',[16])
        db.execute('UPDATE v2_order SET total_amount=-100,handling_amount=1100 WHERE id=16'); db.commit()
        launch(args.php,path,['negative_settle']*4,directory,'negativesettle',[16]*4)
        assert scalar(db,'SELECT status FROM v2_order WHERE id=16') == 0
        assert scalar(db,'SELECT total_amount FROM v2_order WHERE id=16') == -100
        assert scalar(db,'SELECT handling_amount FROM v2_order WHERE id=16') == 1100
        assert scalar(db,"SELECT count(*) FROM v2_payment_attempt WHERE order_id=16 AND status=2 AND provider_no='NEGATIVE_PROVIDER'") == 1
        assert scalar(db,"SELECT count(*) FROM v2_billing_review WHERE order_id=16 AND category='negative_order_amount'") == 1
        assert scalar(db,'SELECT count(*) FROM v2_billing_outbox WHERE order_id=16') == 0
        # 实际 checkout 控制器路径：旧插件负手续费仍有正合计时也不可先向网关收款。
        db.execute("INSERT INTO v2_payment(id,payment,enable,uuid,handling_fee_fixed) VALUES(6,'Epay',1,'PUBLIC_NEGATIVE_FEE',-100),(7,'Epay',1,'PUBLIC_POSITIVE_FEE',100)")
        db.execute("INSERT INTO v2_order(id,user_id,trade_no,total_amount,status) VALUES(17,1,'CHECKOUT17',1000,0),(18,1,'CHECKOUT18',1000,0)"); db.commit()
        launch(args.php,path,['checkout_negative']*6,directory,'negativecheckout',[17]*6)
        assert scalar(db,"SELECT count(*) FROM test_gateway_call WHERE trade_no='CHECKOUT17'") == 0
        assert scalar(db,"SELECT count(*) FROM v2_billing_review WHERE order_id=17 AND category='negative_order_amount'") == 1
        assert scalar(db,'SELECT count(*) FROM v2_order WHERE id=17 AND total_amount=1000 AND handling_amount IS NULL AND payment_id IS NULL AND status=0') == 1
        launch(args.php,path,['checkout_positive'],directory,'positivecheckout',[18])
        assert scalar(db,"SELECT count(*) FROM test_gateway_call WHERE trade_no='CHECKOUT18' AND amount=1100") == 1
        assert scalar(db,'SELECT count(*) FROM v2_order WHERE id=18 AND handling_amount=100 AND payment_id=7 AND status=0') == 1
        assert scalar(db,'PRAGMA integrity_check') == 'ok'
        db.close()

        # 101个已完成事件：前100消费者永久失败，尾部新事件必须在下一批交付。
        fair_path=directory/'fairness.sqlite'
        fair=initialize(fair_path)
        for order_id in range(100,201):
            event_id=hashlib.sha256(('payment.notify.success:'+str(order_id)).encode()).hexdigest()
            fair.execute('INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(?,1,5,?,1000,3)',[order_id,'FAIR'+str(order_id)])
            fair.execute('INSERT INTO v2_billing_outbox(event_id,order_id,event_type,created_at) VALUES(?,?,?,?)',[event_id,order_id,'payment.notify.success',order_id])
        fair.commit()
        launch(args.php,fair_path,['drain_failures'],directory,'fairfirst',[1])
        assert scalar(fair,"SELECT count(*) FROM v2_billing_outbox WHERE order_id<200 AND attempts=1 AND lease_token IS NULL AND lease_until>CAST(strftime('%s','now') AS INTEGER)") == 100
        assert scalar(fair,'SELECT count(*) FROM test_consumer') == 0
        assert scalar(fair,'SELECT attempts FROM v2_billing_outbox WHERE order_id=200') == 0
        launch(args.php,fair_path,['drain_failures'],directory,'fairsecond',[1])
        assert scalar(fair,'SELECT count(*) FROM test_consumer WHERE order_id=200') == 1
        assert scalar(fair,'SELECT count(*) FROM v2_billing_outbox WHERE order_id=200 AND delivered_at IS NOT NULL') == 1
        assert scalar(fair,'SELECT count(*) FROM v2_billing_outbox WHERE order_id<200 AND attempts=1') == 100
        # 所有失败事件已经可重试，但更早可交付的新事件排在退避事件之前。
        fair.execute('UPDATE v2_billing_outbox SET lease_until=1 WHERE order_id<200')
        next_event=hashlib.sha256(b'payment.notify.success:201').hexdigest()
        fair.execute("INSERT INTO v2_order(id,user_id,payment_id,trade_no,total_amount,status) VALUES(201,1,5,'FAIR201',1000,3)")
        fair.execute('INSERT INTO v2_billing_outbox(event_id,order_id,event_type,created_at) VALUES(?,?,?,9999)',[next_event,201,'payment.notify.success'])
        fair.commit()
        launch(args.php,fair_path,['drain_failures'],directory,'fairdue',[1])
        assert scalar(fair,'SELECT count(*) FROM test_consumer WHERE order_id=201') == 1
        assert scalar(fair,'SELECT count(*) FROM v2_billing_outbox WHERE order_id<200 AND attempts=2') == 99
        assert scalar(fair,'PRAGMA integrity_check') == 'ok'
        fair.close()
    print('独立 PHP 进程与真实 SQLite 事务不变量通过；未验证 Laravel 集成或真实支付。')


if __name__ == '__main__':
    main()
