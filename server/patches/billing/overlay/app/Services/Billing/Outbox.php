<?php

namespace App\Services\Billing;

use App\Models\Order;
use App\Services\Plugin\HookManager;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

final class Outbox
{
    public static function order(string $tradeNo): void
    {
        $order=Order::where('trade_no',$tradeNo)->first();
        if ($order) self::deliver((int)$order->id);
    }

    public static function drain(): void
    {
        $pending=Atomic::pending(DB::connection());
        foreach ($pending as $event) self::deliver((int)$event->order_id);
    }

    private static function deliver(int $id): void
    {
        try {
            Atomic::deliver(DB::connection(),$id,function(string $eventId,int $orderId) {
                $order=Order::find($orderId);
                if (!$order) throw new \RuntimeException('到账事件订单不存在');
                // 保留旧钩子的 Order 参数形状，使用非持久 relation 携带稳定事件编号。
                $order->setRelation('billing_event',(object)['id'=>$eventId]);
                HookManager::call('payment.notify.success',$order);
            });
        } catch (\Throwable $e) {
            Log::warning('到账事件交付失败，等待恢复',['order_id'=>$id]);
        }
    }
}
