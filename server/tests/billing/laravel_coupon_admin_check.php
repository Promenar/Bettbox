<?php
/** 真实优惠券服务与管理员付款控制器；仅隔离公开账户和临时库。 */
function fixtureLaravelCouponAdmin($db, string $temporary, callable $makeUser, $plan, callable $request): void
{
    fixtureCheck($db->getDatabaseName()===$temporary.'/fixture.sqlite' && $db->transactionLevel()===0,'coupon_dedicated_database');
    $schema=$db->getSchemaBuilder();
    fixtureCheck(!$schema->hasTable('v2_coupon'),'coupon_empty_owned_table');
    // 对齐当前源迁移的券字段；只创建公开临时表。
    $schema->create('v2_coupon',static function (Illuminate\Database\Schema\Blueprint $table): void {
        $table->integer('id',true);$table->string('code');$table->string('name');
        $table->integer('type');$table->integer('value');$table->boolean('show')->default(false);
        $table->integer('limit_use')->nullable();$table->integer('limit_use_with_user')->nullable();
        $table->string('limit_plan_ids')->nullable();$table->string('limit_period')->nullable();
        $table->integer('started_at');$table->integer('ended_at');$table->integer('created_at');$table->integer('updated_at');
    });
    $makeCoupon=static fn($code)=>App\Models\Coupon::create(['code'=>$code,'name'=>'公开固定金额券','type'=>1,'value'=>1000,'show'=>true,'limit_use'=>1,'started_at'=>time()-3600,'ended_at'=>time()+3600]);
    $coupon=$makeCoupon('PUBLIC_SINGLE_USE');
    $users=[$makeUser('coupon-a',null,1000),$makeUser('coupon-b',null,1000)];
    $out=fixtureParallelBilling($db,$temporary,'parallel_coupon',static function ($i) use ($users,$plan,$coupon): array {
        try {
            App\Services\OrderService::createFromRequest(App\Models\User::findOrFail($users[$i]->id),App\Models\Plan::findOrFail($plan->id),'monthly',$coupon->code);
            return [1];
        } catch (App\Exceptions\ApiException $error) { return [0]; }
    });
    $coupon->refresh();$orders=App\Models\Order::where('coupon_id',$coupon->id)->get();
    fixtureCheck(array_sum(array_column($out,0))===1 && $orders->count()===1 && (int)$coupon->limit_use===0,'coupon_global_one_use_one_order');
    $winner=$orders[0];
    fixtureCheck((int)$winner->discount_amount===1000 && (int)$winner->total_amount===8000 && (int)$winner->balance_amount===1000,'coupon_winner_discount_balance_exact');
    foreach ($users as $i=>$user) {
        $user->refresh();$won=(int)$user->id===(int)$winner->user_id;
        fixtureCheck((int)$user->balance===($won?0:1000) && App\Models\Order::where('user_id',$user->id)->count()===($won?1:0),'coupon_user_'.$i.'_consistent');
    }
    $rollbackCoupon=$makeCoupon('PUBLIC_ROLLBACK_USE');$rollbackUser=$makeUser('coupon-rollback',null,1000);
    $inject=true;
    App\Services\Plugin\HookManager::register('order.create.after',static function ($order) use ($rollbackUser,&$inject): void {
        if ((int)$order->user_id===(int)$rollbackUser->id && $inject) throw new RuntimeException('PUBLIC_COUPON_CREATE_FAILURE');
    });
    $failed=false;
    try { App\Services\OrderService::createFromRequest($rollbackUser,$plan,'monthly',$rollbackCoupon->code); }
    catch (RuntimeException $error) { if (get_class($error)!==RuntimeException::class || $error->getMessage()!=='PUBLIC_COUPON_CREATE_FAILURE') throw $error;$failed=true; }
    finally { $inject=false; }
    $rollbackCoupon->refresh();$rollbackUser->refresh();
    fixtureCheck($failed && (int)$rollbackCoupon->limit_use===1 && (int)$rollbackUser->balance===1000
        && App\Models\Order::where('user_id',$rollbackUser->id)->count()===0,'coupon_create_failure_restores_use_balance_order');
    $retry=App\Services\OrderService::createFromRequest($rollbackUser,$plan,'monthly',$rollbackCoupon->code);
    $rollbackCoupon->refresh();$rollbackUser->refresh();
    fixtureCheck((int)$rollbackCoupon->limit_use===0 && (int)$rollbackUser->balance===0
        && (int)$retry->discount_amount===1000 && (int)$retry->total_amount===8000
        && App\Models\Order::where('user_id',$rollbackUser->id)->count()===1,'coupon_retry_consumes_once');

    $admin=$makeUser('manual-admin');$admin->is_admin=1;$admin->save();
    $buyer=$makeUser('manual-buyer');$order=App\Services\OrderService::createFromRequest($buyer,$plan,'monthly');
    $gateways=$db->table('fixture_gateway')->count();
    $out=fixtureParallelBilling($db,$temporary,'parallel_admin_paid',static function () use ($request,$admin,$order): array {
        return [$request('/fixture/admin-paid',['trade_no'=>$order->trade_no],App\Models\User::findOrFail($admin->id))->getStatusCode()];
    });
    $buyer->refresh();$order->refresh();
    fixtureCheck(in_array(200,array_column($out,0),true) && !array_diff(array_column($out,0),[200,400])
        && (int)$order->status===3 && $order->callback_no==='manual_operation'
        && (int)$buyer->plan_id===(int)$plan->id && (int)$buyer->reset_count===1
        && App\Models\TrafficResetLog::where('user_id',$buyer->id)->count()===1
        && $db->table('fixture_gateway')->count()===$gateways,'admin_paid_open_reset_once_no_gateway');
    $expiry=$buyer->expired_at;
    fixtureCheck($request('/fixture/admin-paid',['trade_no'=>$order->trade_no],$admin)->getStatusCode()===400,'admin_paid_repeat_rejected');
    $buyer->refresh();
    fixtureCheck($buyer->expired_at===$expiry && (int)$buyer->reset_count===1,'admin_paid_repeat_no_extension');
}
