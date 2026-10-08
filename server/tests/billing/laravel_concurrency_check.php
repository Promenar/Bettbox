<?php
/** 只在已隔离临时库中验证真实 Laravel 业务的双进程竞争。 */
function fixtureReapBillingChild(int $pid, array &$children, int $key, int $deadline): int
{
    do {
        $wait=pcntl_waitpid($pid,$status,WNOHANG);
        if ($wait===-1) { unset($children[$key]); throw new RuntimeException('公开子进程身份未确认'); }
        if ($wait>0) {
            // 成功回收立即撤销责任，过期时限不能把 PID 交给 finally。
            unset($children[$key]);
            return $status;
        }
        if (hrtime(true)>$deadline) throw new RuntimeException('公开子进程收尾超时');
        usleep(10000);
    } while (true);
}

function fixtureReapedDeadlineProbe($db): void
{
    fixtureCheck(function_exists('pcntl_fork') && function_exists('pcntl_waitpid') && function_exists('posix_kill'),'parallel_reap_probe_tools');
    $db->disconnect();
    $pid=pcntl_fork();
    if ($pid===-1) throw new RuntimeException('公开收尾探测创建失败');
    if ($pid===0) { while (ob_get_level()>0) ob_end_clean(); exit(0); }
    $children=[0=>$pid];$passed=false;
    try {
        // 已退出子任务遇到过期时限：成功 wait 后不应保留清理责任。
        usleep(200000);
        try {
            $status=fixtureReapBillingChild($pid,$children,0,0);
            $passed=pcntl_wifexited($status) && pcntl_wexitstatus($status)===0 && $children===[];
        } catch (RuntimeException $error) { $passed=false; }
    } finally {
        // 探测自身先核对实际子进程；已回收 PID 绝不发送信号。
        $remaining=pcntl_waitpid($pid,$status,WNOHANG);
        if ($remaining===0) { posix_kill($pid,SIGKILL);pcntl_waitpid($pid,$status); }
        $db->reconnect();
    }
    fixtureCheck($passed,'parallel_reaped_deadline_no_cleanup_responsibility');
}

function fixtureParallelBilling($db, string $temporary, string $label, callable $operation): array
{
    fixtureCheck(function_exists('pcntl_fork') && function_exists('pcntl_waitpid') && function_exists('posix_kill'),$label.'_process_tools');
    fixtureCheck($db->transactionLevel()===0 && $db->getDatabaseName()===$temporary.'/fixture.sqlite',$label.'_dedicated_database');
    $directory=$temporary.'/'.$label;
    fixtureCheck(mkdir($directory,0700),$label.'_owned_directory');
    $db->disconnect();
    $children=[]; $results=[];
    try {
        for ($i=0;$i<2;$i++) {
            $pid=pcntl_fork();
            if ($pid===-1) throw new RuntimeException('公开子进程创建失败');
            if ($pid===0) {
                // 子进程不进入父入口的异常处理或临时目录清理。
                while (ob_get_level()>0) ob_end_clean();
                try {
                    $db->reconnect();
                    if ($db->getDatabaseName()!==$temporary.'/fixture.sqlite' || $db->transactionLevel()!==0) throw new RuntimeException('公开子进程连接拒绝');
                    // 在真实写锁获取后短暂持锁，延长另一个请求的竞争窗口。
                    $delay=true;
                    $db->listen(static function ($query) use (&$delay): void {
                        if ($delay && preg_match('/UPDATE\s+v2_billing_mutex\s+SET/i',$query->sql)) {
                            $delay=false;
                            usleep(200000);
                        }
                    });
                    if (file_put_contents($directory.'/ready-'.$i,'PUBLIC_READY',LOCK_EX)!==12) throw new RuntimeException('公开就绪写入失败');
                    $deadline=hrtime(true)+15000000000;
                    while (!is_file($directory.'/go')) {
                        if (hrtime(true)>$deadline) throw new RuntimeException('公开起跑超时');
                        usleep(10000);
                    }
                    $start=hrtime(true);
                    $values=$operation($i);
                    $end=hrtime(true);
                    if (!is_array($values) || count($values)>8 || array_filter($values,fn($value)=>!is_int($value))) throw new RuntimeException('公开结果类型拒绝');
                    $result=['ok'=>true,'pid'=>getmypid(),'start_ns'=>$start,'end_ns'=>$end,'values'=>$values];
                    $encoded=json_encode($result,JSON_THROW_ON_ERROR);
                    if (file_put_contents($directory.'/result-'.$i,$encoded,LOCK_EX)!==strlen($encoded)) throw new RuntimeException('公开结果写入失败');
                    $db->disconnect();
                    exit(0);
                } catch (Throwable $error) {
                    // 无异常文本、路径或请求/响应正文。
                    exit(1);
                }
            }
            $children[$i]=$pid;
        }
        $deadline=hrtime(true)+15000000000;
        while (!is_file($directory.'/ready-0') || !is_file($directory.'/ready-1')) {
            if (hrtime(true)>$deadline) throw new RuntimeException('公开子进程就绪超时');
            usleep(10000);
        }
        if (file_put_contents($directory.'/go','PUBLIC_GO',LOCK_EX)!==9) throw new RuntimeException('公开起跑失败');
        foreach ($children as $i=>$pid) {
            $status=fixtureReapBillingChild($pid,$children,$i,$deadline);
            fixtureCheck(pcntl_wifexited($status) && pcntl_wexitstatus($status)===0,$label.'_worker_'.$i);
            $result=json_decode(file_get_contents($directory.'/result-'.$i),true,16,JSON_THROW_ON_ERROR);
            fixtureCheck($result['ok']===true && $result['pid']===$pid && is_int($result['start_ns']) && is_int($result['end_ns']) && $result['end_ns']>$result['start_ns'],$label.'_identity_'.$i);
            $results[$i]=$result;
        }
        fixtureCheck(max($results[0]['start_ns'],$results[1]['start_ns'])<min($results[0]['end_ns'],$results[1]['end_ns']),$label.'_overlap');
    } finally {
        // 只终止本方法 fork 后记录且尚未回收的 PID，不按名称清理外部进程。
        foreach ($children as $pid) {
            posix_kill($pid,SIGKILL);
            pcntl_waitpid($pid,$status);
        }
        $db->reconnect();
    }
    return array_map(fn($result)=>$result['values'],$results);
}

function fixtureLaravelConcurrency($db, string $temporary, callable $makeUser, $plan, $positive, callable $request): void
{
    fixtureReapedDeadlineProbe($db);
    $user=$makeUser('parallel-create',null,1000);
    $out=fixtureParallelBilling($db,$temporary,'parallel_create',static function () use ($user,$plan): array {
        try {
            App\Services\OrderService::createFromRequest(App\Models\User::findOrFail($user->id),App\Models\Plan::findOrFail($plan->id),'monthly');
            return [1];
        } catch (App\Exceptions\ApiException $error) { return [0]; }
    });
    $user->refresh();
    $orders=App\Models\Order::where('user_id',$user->id)->get();
    fixtureCheck(array_sum(array_column($out,0))===1 && $orders->count()===1 && (int)$user->balance===0 && (int)$orders[0]->balance_amount===1000 && (int)$orders[0]->total_amount===9000,'parallel_create_one_order_balance_once');
    $order=$orders[0];
    $out=fixtureParallelBilling($db,$temporary,'parallel_cancel',static function () use ($request,$user,$order): array {
        return [$request('/fixture/cancel',['trade_no'=>$order->trade_no],App\Models\User::findOrFail($user->id))->getStatusCode()];
    });
    $user->refresh();$order->refresh();
    fixtureCheck(!array_diff(array_column($out,0),[200,400]) && (int)$user->balance===1000 && (int)$order->status===2,'parallel_cancel_refund_once');

    $payer=$makeUser('parallel-notify');
    $payment=App\Services\OrderService::createFromRequest($payer,$plan,'monthly');
    $payment->payment_id=$positive->id;$payment->save();
    $out=fixtureParallelBilling($db,$temporary,'parallel_notify',static function () use ($request,$payment): array {
        return [$request('/api/v1/guest/payment/notify/FixtureLegacy/PUBLIC_POSITIVE',['trade_no'=>$payment->trade_no,'callback_no'=>'PUBLIC_PARALLEL_'.$payment->id])->getStatusCode()];
    });
    $payer->refresh();$payment->refresh();
    fixtureCheck(array_column($out,0)===[200,200] && (int)$payment->status===3 && (int)$payer->reset_count===1
        && App\Models\TrafficResetLog::where('user_id',$payer->id)->count()===1
        && $db->table('fixture_consumer')->where('order_id',$payment->id)->count()===1,'parallel_notify_open_reset_event_once');

    $raceUser=$makeUser('parallel-race',null,1000);
    $race=App\Services\OrderService::createFromRequest($raceUser,$plan,'monthly');
    $race->payment_id=$positive->id;$race->save();
    $out=fixtureParallelBilling($db,$temporary,'parallel_cancel_paid',static function ($i) use ($request,$raceUser,$race): array {
        return [$i===0
            ? $request('/fixture/cancel',['trade_no'=>$race->trade_no],App\Models\User::findOrFail($raceUser->id))->getStatusCode()
            : $request('/api/v1/guest/payment/notify/FixtureLegacy/PUBLIC_POSITIVE',['trade_no'=>$race->trade_no,'callback_no'=>'PUBLIC_RACE_'.$race->id])->getStatusCode()];
    });
    $raceUser->refresh();$race->refresh();
    $cancelled=(int)$race->status===2;
    fixtureCheck(!array_diff(array_column($out,0),[200,400]) && in_array((int)$race->status,[2,3],true)
        && (int)$raceUser->balance===($cancelled?1000:0)
        && (int)$raceUser->reset_count===($cancelled?0:1)
        && $db->table('fixture_consumer')->where('order_id',$race->id)->count()===($cancelled?0:1)
        && (!$cancelled || $db->table('v2_billing_review')->where('order_id',$race->id)->where('category','cancelled_payment')->count()===1),'parallel_cancel_paid_consistent_winner');

    $inviter=$makeUser('parallel-commission-inviter');
    $buyer=$makeUser('parallel-commission-buyer',$inviter->id);
    $commission=App\Services\OrderService::createFromRequest($buyer,$plan,'monthly');
    $commission->payment_id=$positive->id;$commission->save();
    fixtureCheck($request('/api/v1/guest/payment/notify/FixtureLegacy/PUBLIC_POSITIVE',['trade_no'=>$commission->trade_no,'callback_no'=>'PUBLIC_COMMISSION_'.$commission->id])->getStatusCode()===200,'parallel_commission_order_opened');
    $commission->refresh();$commission->commission_status=1;$commission->save();
    $out=fixtureParallelBilling($db,$temporary,'parallel_commission',static function (): array {
        return [Illuminate\Support\Facades\Artisan::call('check:commission')];
    });
    $inviter->refresh();$commission->refresh();
    fixtureCheck(array_column($out,0)===[0,0] && (int)$commission->commission_status===2 && (int)$commission->actual_commission_balance===1000
        && (int)$inviter->commission_balance===1000 && App\Models\CommissionLog::where('order_id',$commission->id)->count()===1,'parallel_commission_balance_log_once');
}
