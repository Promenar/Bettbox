<?php

require __DIR__ . '/PdoConnection.php';
require __DIR__ . '/../../patches/billing/overlay/app/Services/Billing/Atomic.php';
use App\Services\Billing\Atomic;

$db = new PdoConnection($argv[1]);
$operation = $argv[2];
$barrier = $argv[3];
// 独立进程等待同一启动屏障；只操作测试临时目录。
$deadline = microtime(true) + 15;
touch($barrier . '.ready.' . getmypid());
while (!is_file($barrier)) {
    if (microtime(true) > $deadline) throw new RuntimeException('测试屏障超时');
    usleep(1000);
}
$id = (int)($argv[4] ?? 1);
switch ($operation) {
    case 'paid':
        Atomic::paid($db, $id, 'LEGACY_FIXTURE', 'legacy');
        break;
    case 'cancel':
        Atomic::cancel($db, $id, function ($order) use ($db) {
            return $db->affectingStatement('UPDATE v2_user SET balance=balance+? WHERE id=?', [$order->balance_amount,$order->user_id]) === 1;
        });
        break;
    case 'open':
        Atomic::open($db, 'ORDER1', function ($order) use ($db) {
            if ((int)$order->status !== 1) return;
            $db->affectingStatement('UPDATE v2_user SET opened=opened+1 WHERE id=?', [$order->user_id]);
            $db->affectingStatement('UPDATE v2_order SET status=3 WHERE id=? AND status=1', [$order->id]);
        });
        break;
    case 'open_fail':
        try {
            $order=$db->selectOne('SELECT trade_no FROM v2_order WHERE id=?',[$id]);
            Atomic::open($db,$order->trade_no,function($order) use ($db) {
                $db->affectingStatement('UPDATE v2_user SET opened=opened+1 WHERE id=?',[$order->user_id]);
                throw new RuntimeException('公开首次开通故障');
            });
        } catch (RuntimeException $e) {}
        break;
    case 'open_recover':
        $order=$db->selectOne('SELECT trade_no FROM v2_order WHERE id=?',[$id]);
        Atomic::open($db,$order->trade_no,function($order) use ($db) {
            if ((int)$order->status!==1) return;
            $db->affectingStatement('UPDATE v2_user SET opened=opened+1 WHERE id=?',[$order->user_id]);
            $db->affectingStatement('UPDATE v2_order SET status=3 WHERE id=? AND status=1',[$order->id]);
        });
        break;
    case 'deliver':
    case 'deliver_crash':
        Atomic::deliver($db,$id,function($eventId,$orderId) use ($db,$operation) {
            // 独立连接模拟外部消费者；其事件ID唯一约束承担幂等。
            $consumer=new PdoConnection($GLOBALS['argv'][1]);
            $consumer->transaction(function() use ($consumer,$eventId,$orderId) {
                $consumer->insert('INSERT OR IGNORE INTO test_consumer(event_id,order_id) VALUES(?,?)',[$eventId,$orderId]);
            });
            // 消费者落地后进程崩溃，故意跳过 outbox 确认和 catch 清理。
            if ($operation==='deliver_crash') exit(0);
        });
        break;
    case 'drain_failures':
        foreach (Atomic::pending($db) as $event) {
            try {
                Atomic::deliver($db,(int)$event->order_id,function($eventId,$orderId) use ($db) {
                    if ($orderId<200) throw new RuntimeException('公开永久失败消费者');
                    $db->insert('INSERT OR IGNORE INTO test_consumer(event_id,order_id) VALUES(?,?)',[$eventId,$orderId]);
                });
            } catch (RuntimeException $e) {}
        }
        break;
    case 'negative_attempt':
        try {
            Atomic::attempt($db,$id,['payment_id'=>5,'identity_mode'=>'merchant','identity_key'=>'PUBLIC_FIXTURE','merchant_id'=>123,'store_id'=>456,'expected_cents'=>100,'secret_ref'=>'public_fixture']);
        } catch (RuntimeException $e) {
            if ($e->getMessage()!=='订单金额无效，拒绝付呗下单并等待人工核对') throw $e;
            break;
        }
        throw new RuntimeException('负数订单创建付呗尝试');
    case 'negative_settle':
        $attempt=$db->selectOne('SELECT * FROM v2_payment_attempt WHERE order_id=?',[$id]);
        if (Atomic::settleAttempt($db,$attempt->external_no,'NEGATIVE_PROVIDER',$attempt->provider_scope,123,456,1000)) throw new RuntimeException('负数订单按快照到账');
        break;
    case 'negative_paid_sources':
        foreach (['legacy','manual','free'] as $source) {
            if (Atomic::paid($db,$id,'NEGATIVE_SOURCE_FIXTURE',$source)) throw new RuntimeException('负数金额进入到账态');
        }
        break;
    case 'negative_open':
        $order=$db->selectOne('SELECT trade_no FROM v2_order WHERE id=?',[$id]);
        Atomic::open($db,$order->trade_no,function($order) use ($db) {
            // 如果错误执行开通，真实SQL副作用和异常使本进程验收失败。
            $db->affectingStatement('UPDATE v2_user SET opened=opened+1,balance=balance+999 WHERE id=?',[$order->user_id]);
            throw new RuntimeException('负数PROCESSING错误执行开通副作用');
        });
        break;
    case 'free_negative':
        if (Atomic::paid($db,$id,'NEGATIVE_FREE_FIXTURE','free')) throw new RuntimeException('负数订单被免费开通');
        break;
    case 'commission':
        Atomic::commission($db,$id,[0=>100],false);
        break;
    case 'cycle':
        try { Atomic::commission($db,$id,[0=>50,1=>30,2=>20],false); }
        catch (RuntimeException $e) { Atomic::review($db,$id,'commission_failed','循环邀请测试，待人工核对'); }
        break;
    case 'rollback':
        try {
            Atomic::run($db, function ($db) {
                $db->affectingStatement('UPDATE v2_user SET balance=balance+999 WHERE id=1');
                throw new RuntimeException('公开故障注入');
            });
        } catch (RuntimeException $e) {}
        break;
    case 'attempt':
        Atomic::attempt($db, $id, ['payment_id'=>5,'identity_mode'=>'merchant','identity_key'=>'PUBLIC_FIXTURE','merchant_id'=>123,'store_id'=>456,'expected_cents'=>1000,'secret_ref'=>'public_fixture']);
        break;
    case 'settle':
        $attempt = $db->selectOne('SELECT * FROM v2_payment_attempt WHERE order_id=?', [$id]);
        Atomic::settleAttempt($db,$attempt->external_no,'PROVIDER_FIXTURE',$attempt->provider_scope,123,456,1000);
        break;
    default:
        throw new RuntimeException('未知测试操作');
}
