<?php

namespace App\Console\Commands;

use App\Models\CommissionLog;
use Illuminate\Console\Command;
use App\Models\Order;
use App\Models\User;
use Illuminate\Support\Facades\DB;

class CheckCommission extends Command
{
    /**
     * The name and signature of the console command.
     *
     * @var string
     */
    protected $signature = 'check:commission';

    /**
     * The console command description.
     *
     * @var string
     */
    protected $description = '返佣服务';

    /**
     * Create a new command instance.
     *
     * @return void
     */
    public function __construct()
    {
        parent::__construct();
    }

    /**
     * Execute the console command.
     *
     * @return mixed
     */
    public function handle()
    {
        $this->autoCheck();
        $this->autoPayCommission();
    }

    public function autoCheck()
    {
        if ((int)admin_setting('commission_auto_check_enable', 1)) {
            Order::where('commission_status', 0)
                ->where('invite_user_id', '!=', NULL)
                ->where('status', 3)
                ->where('updated_at', '<=', strtotime('-3 day', time()))
                ->update([
                    'commission_status' => 1
                ]);
        }
    }

    public function autoPayCommission()
    {
        $orders = Order::where('commission_status', 1)->whereNotNull('invite_user_id')->get();
        foreach ($orders as $order) {
            try {
                $this->payHandle($order->invite_user_id, $order);
            } catch (\Throwable $e) {
                \App\Services\Billing\Atomic::review(DB::connection(), (int)$order->id, 'commission_failed', '佣金事务未完成，需人工核对或修复后重试');
            }
        }
    }

    public function payHandle($inviteUserId, Order $order)
    {
        $shares = (int)admin_setting('commission_distribution_enable', 0)
            ? [0=>(int)admin_setting('commission_distribution_l1'),1=>(int)admin_setting('commission_distribution_l2'),2=>(int)admin_setting('commission_distribution_l3')]
            : [0=>100];
        // 受益人只采用事务内重读的订单字段，忽略陈旧调用参数。
        $ok = \App\Services\Billing\Atomic::commission(DB::connection(), (int)$order->id, $shares, (bool)admin_setting('withdraw_close_enable', 0));
        $order->refresh();
        return $ok;
    }
}
