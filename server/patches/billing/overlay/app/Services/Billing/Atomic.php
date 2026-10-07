<?php

namespace App\Services\Billing;

final class Atomic
{
    public static function run($db, callable $action)
    {
        if ($db->getDriverName() !== 'sqlite') throw new \RuntimeException('计费候选仅支持已验收的 SQLite 目标');
        return $db->transaction(function () use ($db, $action) {
            // 必须先写后读：SQLite 的 lockForUpdate 不能替代此写锁获取步骤。
            if ($db->affectingStatement('UPDATE v2_billing_mutex SET revision=revision+1 WHERE id=1') !== 1) {
                throw new \RuntimeException('计费事务迁移未完成');
            }
            return $action($db);
        }, 5);
    }

    public static function paid($db, int $id, string $callback, string $source, ?callable $transition = null): bool
    {
        if (!in_array($source, ['legacy', 'free', 'manual'], true) || $callback === '') return false;
        $transitioned = false;
        $result = self::run($db, function ($db) use ($id, $callback, $source, &$transitioned) {
            $transitioned = false;
            $order = $db->selectOne('SELECT * FROM v2_order WHERE id=?', [$id]);
            if (!$order) return false;
            if (!self::guardAmountsInside($db,$order)) return false;
            if ((int) $order->status === 2) {
                if ($source === 'legacy') self::reviewInside($db, $id, 'cancelled_payment', '取消后收到付款，待人工核对');
                return false;
            }
            if ((int) $order->status !== 0) return in_array((int) $order->status, [1, 3], true) && $order->callback_no === $callback;
            if ($source === 'free' && (string) $order->total_amount !== '0') return false;
            $changed = $db->affectingStatement('UPDATE v2_order SET status=1,callback_no=?,paid_at=?,updated_at=? WHERE id=? AND status=0', [$callback, time(), time(), $id]) === 1;
            if ($changed && $source === 'legacy') self::enqueueInside($db,$id);
            $transitioned = $changed;
            return $changed;
        });
        if ($result && $transitioned && $transition) $transition();
        return $result;
    }

    public static function cancel($db, int $id, callable $refund, ?callable $before = null, ?callable $transition = null): bool
    {
        return self::run($db, function ($db) use ($id, $refund, $before, $transition) {
            $order = $db->selectOne('SELECT * FROM v2_order WHERE id=?', [$id]);
            if (!$order) return false;
            if ((int) $order->status === 2) return true;
            if ((int) $order->status !== 0) return false;
            if ($before) $before();
            if ($db->affectingStatement('UPDATE v2_order SET status=2,updated_at=? WHERE id=? AND status=0', [time(), $id]) !== 1) return false;
            if ((int) ($order->balance_amount ?? 0) > 0 && !$refund($order)) throw new \RuntimeException('取消订单余额退回失败');
            if ($transition) $transition();
            return true;
        });
    }

    public static function open($db, string $tradeNo, callable $action): void
    {
        self::run($db, function ($db) use ($tradeNo, $action) {
            $order = $db->selectOne('SELECT * FROM v2_order WHERE trade_no=?', [$tradeNo]);
            if ($order && in_array((int) $order->status, [0, 1], true) && self::guardAmountsInside($db,$order)) $action($order);
        });
    }

    public static function guardAmountsInside($db,$order): bool
    {
        // 调用方必须持有同一连接的写事务；不抛异常，确保核对证据随事务提交。
        if ($order->total_amount < 0 || ($order->handling_amount ?? 0) < 0) {
            self::reviewInside($db,(int)$order->id,'negative_order_amount','订单金额或手续费为负数，拒绝到账和开通，保留原始证据待人工核对');
            return false;
        }
        return true;
    }

    public static function review($db, int $id, string $category, string $reason): void
    {
        self::run($db, fn($db) => self::reviewInside($db, $id, $category, $reason));
    }

    public static function commission($db, int $id, array $shares, bool $toBalance): bool
    {
        foreach ($shares as $level => $share) {
            if (!is_int($level) || $level < 0 || $level > 2 || !is_int($share) || $share < 0 || $share > 100) throw new \InvalidArgumentException('佣金层级比例不合法');
        }
        return self::run($db, function ($db) use ($id,$shares,$toBalance) {
            $order = $db->selectOne('SELECT * FROM v2_order WHERE id=?', [$id]);
            if (!$order) return false;
            if ((int)$order->commission_status === 2) return true;
            if ((int)$order->commission_status !== 1 || (int)$order->status !== 3) return false;
            if ($db->selectOne('SELECT id FROM v2_commission_log WHERE trade_no=? AND order_id IS NULL LIMIT 1', [$order->trade_no])) throw new \RuntimeException('历史佣金证据需人工核对');
            $base = $order->commission_balance;
            if (!preg_match('/^(0|[1-9][0-9]{0,9})$/D',(string)$base) || (int)$base > 1000000000) throw new \RuntimeException('佣金基数不是合法整数分');
            $seen = [(int)$order->user_id => true];
            $beneficiary = $order->invite_user_id;
            $total = 0;
            for ($level = 0; $level < 3 && isset($shares[$level]); $level++) {
                $user = $db->selectOne('SELECT id,invite_user_id FROM v2_user WHERE id=?', [$beneficiary]);
                if (!$user) break;
                if (isset($seen[$user->id])) throw new \RuntimeException('循环邀请拒绝重复受益人');
                $seen[$user->id] = true;
                $product = (int)$base * $shares[$level];
                if ($product % 100 !== 0) throw new \RuntimeException('佣金存在非整数分，需确认舍入政策');
                $amount = intdiv($product,100);
                if ($amount > 0) {
                    $db->insert('INSERT INTO v2_commission_log(invite_user_id,user_id,trade_no,order_amount,get_amount,created_at,updated_at,order_id,level) VALUES(?,?,?,?,?,?,?,?,?)', [$user->id,$order->user_id,$order->trade_no,$order->total_amount,$amount,time(),time(),$id,$level]);
                    $column = $toBalance ? 'balance' : 'commission_balance';
                    if ($db->affectingStatement('UPDATE v2_user SET ' . $column . '=' . $column . '+?,updated_at=? WHERE id=?', [$amount,time(),$user->id]) !== 1) throw new \RuntimeException('佣金余额保存失败');
                    $total += $amount;
                }
                $beneficiary = $user->invite_user_id;
            }
            return $db->affectingStatement('UPDATE v2_order SET commission_status=2,actual_commission_balance=COALESCE(actual_commission_balance,0)+?,updated_at=? WHERE id=? AND commission_status=1', [$total,time(),$id]) === 1;
        });
    }

    private static function reviewInside($db, int $id, string $category, string $reason): void
    {
        $db->insert('INSERT OR IGNORE INTO v2_billing_review(order_id,category,reason,created_at) VALUES(?,?,?,?)', [$id, $category, $reason, time()]);
    }

    public static function attempt($db, int $orderId, array $snapshot): object
    {
        foreach (['payment_id','merchant_id','store_id','expected_cents'] as $key) {
            if (!isset($snapshot[$key]) || !preg_match('/^[1-9][0-9]{0,10}$/D', (string) $snapshot[$key])) throw new \InvalidArgumentException('付呗快照必需编号或金额缺失');
        }
        if ((int)$snapshot['expected_cents'] > 1000000000) throw new \InvalidArgumentException('付呗快照金额超出范围');
        if (!is_string($snapshot['secret_ref'] ?? null) || !preg_match('/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/D',$snapshot['secret_ref'])) throw new \InvalidArgumentException('付呗快照密钥引用未配置');
        if (!isset($snapshot['identity_mode'], $snapshot['identity_key']) || !in_array($snapshot['identity_mode'], ['merchant','vendor'], true)
            || !preg_match('/^[a-zA-Z0-9_-]{1,32}$/D', $snapshot['identity_key'])) throw new \InvalidArgumentException('付呗快照身份不合法');
        $result = self::run($db, function ($db) use ($orderId, $snapshot) {
            $order = $db->selectOne('SELECT * FROM v2_order WHERE id=?', [$orderId]);
            if ($order && !self::guardAmountsInside($db,$order)) return null;
            if (!$order || (int) $order->status !== 0 || (int) $order->payment_id !== (int) $snapshot['payment_id']
                || (int) $order->total_amount + (int) ($order->handling_amount ?? 0) !== (int) $snapshot['expected_cents']) throw new \RuntimeException('付呗快照与当前订单不匹配');
            $scope = hash('sha256', json_encode([$snapshot['identity_mode'],$snapshot['identity_key'],(string)$snapshot['merchant_id']]));
            $previous = $db->selectOne('SELECT * FROM v2_payment_attempt WHERE order_id=? AND status=0 ORDER BY id DESC LIMIT 1', [$orderId]);
            if ($previous) {
                foreach (['payment_id','merchant_id','store_id','expected_cents'] as $key) {
                    if ((string) $previous->$key !== (string) $snapshot[$key]) throw new \RuntimeException('存在不同快照的未完成尝试，先人工核对或关闭平台订单');
                }
                if ($previous->provider_scope !== $scope || $previous->secret_ref !== $snapshot['secret_ref']) throw new \RuntimeException('未完成尝试身份或密钥引用冲突');
                return $previous;
            }
            $external = bin2hex(random_bytes(16));
            $db->insert('INSERT INTO v2_payment_attempt(order_id,payment_id,external_no,identity_mode,identity_key,provider_scope,merchant_id,store_id,expected_cents,secret_ref,status,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,0,?)', [$orderId,$snapshot['payment_id'],$external,$snapshot['identity_mode'],$snapshot['identity_key'],$scope,$snapshot['merchant_id'],$snapshot['store_id'],$snapshot['expected_cents'],$snapshot['secret_ref'],time()]);
            return $db->selectOne('SELECT * FROM v2_payment_attempt WHERE external_no=?', [$external]);
        });
        if (!$result) throw new \RuntimeException('订单金额无效，拒绝付呗下单并等待人工核对');
        return $result;
    }

    public static function settleAttempt($db, string $external, string $providerNo, string $scope, int $merchant, int $store, int $cents, ?callable $transition = null): bool
    {
        if (!preg_match('/^[a-zA-Z0-9_-]{1,32}$/D', $providerNo)) return false;
        $transitioned = false;
        $result = self::run($db, function ($db) use ($external,$providerNo,$scope,$merchant,$store,$cents,&$transitioned) {
            $transitioned = false;
            $attempt = $db->selectOne('SELECT * FROM v2_payment_attempt WHERE external_no=?', [$external]);
            if (!$attempt || $attempt->provider_scope !== $scope || (int)$attempt->merchant_id !== $merchant || (int)$attempt->store_id !== $store || (int)$attempt->expected_cents !== $cents) return false;
            if ($attempt->provider_no !== null && $attempt->provider_no !== $providerNo) return false;
            $order = $db->selectOne('SELECT * FROM v2_order WHERE id=?', [$attempt->order_id]);
            if (!$order) return false;
            if (!self::guardAmountsInside($db,$order)) {
                if ((int)$attempt->status===0) {
                    // 已验签的平台流水仍保存为人工核对证据，不开通或修正原始金额。
                    $db->affectingStatement('UPDATE v2_payment_attempt SET provider_no=COALESCE(provider_no,?),status=2 WHERE id=? AND status=0',[$providerNo,$attempt->id]);
                }
                return false;
            }
            if ((int)$attempt->status === 1) return in_array((int)$order->status,[1,3],true) && $order->callback_no === $providerNo;
            if ((int)$attempt->status !== 0) return false;
            $db->affectingStatement('UPDATE v2_payment_attempt SET provider_no=? WHERE id=? AND provider_no IS NULL', [$providerNo,$attempt->id]);
            if ((int)$order->status !== 0 || (int)$order->payment_id !== (int)$attempt->payment_id) {
                $db->affectingStatement('UPDATE v2_payment_attempt SET status=2 WHERE id=?', [$attempt->id]);
                self::reviewInside($db,(int)$order->id,'attempt_conflict','收到付款但订单状态或归属冲突，待人工核对');
                return false;
            }
            if ($db->affectingStatement('UPDATE v2_order SET status=1,callback_no=?,paid_at=?,updated_at=? WHERE id=? AND status=0', [$providerNo,time(),time(),$order->id]) !== 1) throw new \RuntimeException('到账 CAS 失败');
            $db->affectingStatement('UPDATE v2_payment_attempt SET status=1 WHERE id=? AND status=0', [$attempt->id]);
            self::enqueueInside($db,(int)$order->id);
            $transitioned = true;
            return true;
        });
        if ($result && $transitioned && $transition) $transition();
        return $result;
    }

    private static function enqueueInside($db,int $orderId): void
    {
        $eventId = hash('sha256','payment.notify.success:' . $orderId);
        $db->insert('INSERT OR IGNORE INTO v2_billing_outbox(event_id,order_id,event_type,created_at) VALUES(?,?,?,?)',[$eventId,$orderId,'payment.notify.success',time()]);
    }

    public static function pending($db,int $limit=100): array
    {
        if ($limit<1 || $limit>100) throw new \InvalidArgumentException('事件领取批量超出范围');
        // 先挑最早可交付时间；失败事件退避后不占据下一批，永久失败不会饿死新事件。
        return $db->select('SELECT e.order_id FROM v2_billing_outbox e JOIN v2_order o ON o.id=e.order_id WHERE e.delivered_at IS NULL AND e.lease_until<=? AND o.status=3 ORDER BY e.lease_until,e.created_at,e.event_id LIMIT ' . $limit,[time()]);
    }

    public static function deliver($db,int $orderId,callable $consumer): bool
    {
        $claim = self::run($db,function($db) use ($orderId) {
            $order = $db->selectOne('SELECT status FROM v2_order WHERE id=?',[$orderId]);
            if (!$order || (int)$order->status !== 3) return null;
            $event = $db->selectOne('SELECT * FROM v2_billing_outbox WHERE order_id=? AND delivered_at IS NULL AND lease_until<=?',[$orderId,time()]);
            if (!$event) return null;
            $token=bin2hex(random_bytes(16));
            if ($db->affectingStatement('UPDATE v2_billing_outbox SET lease_token=?,lease_until=?,attempts=attempts+1 WHERE event_id=? AND delivered_at IS NULL AND lease_until<=?',[$token,time()+60,$event->event_id,time()])!==1) return null;
            $event->lease_token=$token;
            $event->attempts=(int)$event->attempts+1;
            return $event;
        });
        if (!$claim) return false;
        try {
            // 数据库外交付；消费者必须按稳定 event_id 幂等，失败和崩溃允许重复交付。
            $consumer($claim->event_id,(int)$claim->order_id);
            return self::run($db,fn($db)=>$db->affectingStatement('UPDATE v2_billing_outbox SET delivered_at=?,lease_until=0,lease_token=NULL WHERE event_id=? AND lease_token=? AND delivered_at IS NULL',[time(),$claim->event_id,$claim->lease_token])===1);
        } catch (\Throwable $e) {
            // 可重试失败按30秒指数退避，封顶1小时；租约token仍需CAS核对。
            $retryAt=time()+min(3600,30*(2**min(7,$claim->attempts-1)));
            self::run($db,fn($db)=>$db->affectingStatement('UPDATE v2_billing_outbox SET lease_until=?,lease_token=NULL WHERE event_id=? AND lease_token=? AND delivered_at IS NULL',[$retryAt,$claim->event_id,$claim->lease_token]));
            throw $e;
        }
    }
}
