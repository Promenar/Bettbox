<?php
/** 实际 Laravel 数据库异步队列；只使用已验证的临时空库与公开任务。 */
function fixtureLaravelDatabaseQueue($db, string $temporary, callable $makeUser, $plan): void
{
    fixtureCheck($db->getDatabaseName()===$temporary.'/fixture.sqlite' && $db->transactionLevel()===0,'queue_dedicated_database');
    $schema=$db->getSchemaBuilder();
    fixtureCheck(!$schema->hasTable('fixture_jobs'),'queue_empty_owned_table');
    // 字段和索引取自当前镜像 Laravel 官方 jobs.stub。
    $schema->create('fixture_jobs',static function (Illuminate\Database\Schema\Blueprint $table): void {
        $table->bigIncrements('id');$table->string('queue');$table->longText('payload');
        $table->unsignedTinyInteger('attempts');$table->unsignedInteger('reserved_at')->nullable();
        $table->unsignedInteger('available_at');$table->unsignedInteger('created_at');
        $table->index(['queue','reserved_at','available_at']);
    });
    $config=app('config');$saved=$config->get('queue');
    $config->set('queue.connections.fixture_async',['driver'=>'database','connection'=>'fixture','table'=>'fixture_jobs','queue'=>'order_handle','retry_after'=>60,'after_commit'=>false]);
    $config->set('queue.default','fixture_async');
    try {
        $user=$makeUser('async-queue');
        $order=App\Services\OrderService::createFromRequest($user,$plan,'monthly');
        fixtureCheck(App\Services\Billing\Atomic::paid($db,(int)$order->id,'PUBLIC_ASYNC_'.$order->id,'legacy'),'queue_paid_without_inline_open');
        $order->refresh();$user->refresh();
        fixtureCheck((int)$order->status===1 && $user->plan_id===null && (int)$user->reset_count===0,'queue_processing_not_opened');
        $fail=true;$failed=false;
        App\Services\Plugin\HookManager::register('order.open.before',static function ($current) use ($order,&$fail): void {
            if ((int)$current->id===(int)$order->id && $fail) { $fail=false;throw new RuntimeException('公开异步开通故障'); }
        });
        app('events')->listen(Illuminate\Queue\Events\JobExceptionOccurred::class,static function () use (&$failed): void { $failed=true; });
        fixtureCheck(Illuminate\Support\Facades\Artisan::call('check:order')===0,'queue_real_compensation_command');
        $targetJobs=static function () use ($db,$order): array {
            return $db->table('fixture_jobs')->orderBy('id')->get()->filter(static function ($row) use ($order): bool {
                $payload=json_decode($row->payload,true,32,JSON_THROW_ON_ERROR);
                return ($payload['displayName']??null)===App\Jobs\OrderHandleJob::class
                    && str_contains($payload['data']['command']??'',$order->trade_no);
            })->all();
        };
        fixtureCheck(count($targetJobs())===1 && (int)App\Models\Order::findOrFail($order->id)->status===1,'queue_serialized_job_not_sync');
        $workerFactory=static fn()=>new Illuminate\Queue\Worker(app('queue'),app('events'),app(Illuminate\Contracts\Debug\ExceptionHandler::class),static fn()=>false);
        $options=new Illuminate\Queue\WorkerOptions(sleep:0,maxTries:3,backoff:0);
        $worker=$workerFactory();
        // CheckOrder 也会排入既有公开负数订单；只在实际异常事件出现后停止。
        for ($i=0;$i<6 && !$failed;$i++) $worker->runNextJob('fixture_async','order_handle',$options);
        $jobs=$targetJobs();$order->refresh();$user->refresh();
        fixtureCheck($failed && !$fail && count($jobs)===1 && (int)reset($jobs)->attempts===1
            && reset($jobs)->reserved_at===null,'queue_failed_job_released_for_retry');
        fixtureCheck((int)$order->status===1 && $user->plan_id===null && (int)$user->reset_count===0
            && App\Models\TrafficResetLog::where('user_id',$user->id)->count()===0
            && $db->table('fixture_consumer')->where('order_id',$order->id)->count()===0,'queue_failure_business_transaction_rolled_back');
        App\Jobs\OrderHandleJob::dispatch($order->trade_no);
        fixtureCheck(count($targetJobs())===2,'queue_duplicate_serialized_jobs');
        $out=fixtureParallelBilling($db,$temporary,'parallel_queue',static function () use ($workerFactory,$order): array {
            $processed=0;$pid=getmypid();
            app('events')->listen(Illuminate\Queue\Events\JobProcessed::class,static function ($event) use (&$processed,$pid,$order): void {
                $payload=$event->job->payload();
                if (getmypid()===$pid && $event->connectionName==='fixture_async'
                    && ($payload['displayName']??null)===App\Jobs\OrderHandleJob::class
                    && str_contains($payload['data']['command']??'',$order->trade_no)) $processed++;
            });
            $worker=$workerFactory();$options=new Illuminate\Queue\WorkerOptions(sleep:0,maxTries:3,backoff:0);
            // 每个 PID 消费一个目标任务即停止；空取或保守重试有界。
            for ($i=0;$i<10 && $processed===0;$i++) {
                $worker->runNextJob('fixture_async','order_handle',$options);
                if ($processed===0) usleep(50000);
            }
            return [$processed];
        });
        fixtureCheck(array_column($out,0)===[1,1],'queue_two_pids_processed_target_once');
        $order->refresh();$user->refresh();
        fixtureCheck(array_column($out,0)===[1,1] && $targetJobs()===[] && $db->table('fixture_jobs')->count()===0,'queue_workers_consumed_persistent_jobs');
        fixtureCheck((int)$order->status===3 && (int)$user->plan_id===(int)$plan->id && (int)$user->reset_count===1
            && App\Models\TrafficResetLog::where('user_id',$user->id)->count()===1
            && $db->table('fixture_consumer')->where('order_id',$order->id)->count()===1
            && $db->table('v2_billing_outbox')->where('order_id',$order->id)->whereNotNull('delivered_at')->count()===1,'queue_duplicate_retry_open_reset_event_once');
    } finally {
        $config->set('queue',$saved);
    }
    fixtureCheck($config->get('queue')===$saved,'queue_configuration_restored');
}
