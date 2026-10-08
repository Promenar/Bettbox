<?php

namespace App\Console\Commands;

use App\Services\Billing\AtomicMigration;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Throwable;

class BillingMigrate extends Command
{
    protected $signature = 'billing:migrate {--execute : 执行固定账务迁移} {--rollback : 回滚无新增账务证据的候选}';
    protected $description = '固定账务迁移与迁移仓库原子执行，默认只输出计划';

    public function handle(): int
    {
        $rollback = (bool)$this->option('rollback');
        if (!$this->option('execute')) {
            $this->line(json_encode(['mode'=>'plan','operation'=>$rollback?'down':'up','database_changed'=>false],JSON_THROW_ON_ERROR));
            return self::SUCCESS;
        }
        try {
            $result = AtomicMigration::perform(DB::connection(),app('migrator'),base_path(AtomicMigration::RELATIVE_PATH),$rollback);
            $this->line(json_encode($result,JSON_THROW_ON_ERROR));
            return self::SUCCESS;
        } catch (Throwable $error) {
            // 固定失败回执不暴露数据库、路径、配置或底层异常正文。
            $this->line(json_encode(['operation'=>$rollback?'down':'up','completed'=>false,'code'=>'migrationUnconfirmed'],JSON_THROW_ON_ERROR));
            return self::FAILURE;
        }
    }
}
