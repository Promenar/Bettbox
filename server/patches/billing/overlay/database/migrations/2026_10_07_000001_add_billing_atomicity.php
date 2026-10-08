<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;

return new class extends Migration {
    public function up(): void
    {
        $connection = DB::connection();
        if ($connection->getDriverName() !== 'sqlite') throw new RuntimeException('候选迁移仅接受 SQLite');
        // SQLite grammar 不自动包裹迁移事务，检查与全部 DDL 必须共同撤销。
        $connection->transaction(function () use ($connection): void {
            $schema = $connection->getSchemaBuilder();
            foreach (['v2_billing_mutex','v2_payment_attempt','v2_billing_review','v2_billing_outbox'] as $table) {
                if ($schema->hasTable($table)) throw new RuntimeException('计费表已存在，请核对迁移来源');
            }
            if ($schema->hasColumn('v2_commission_log','order_id') || $schema->hasColumn('v2_commission_log','level')) throw new RuntimeException('佣金列已存在，请核对迁移来源');
            $connection->unprepared(file_get_contents(__DIR__ . '/billing_atomic_schema.sql'));
        });
    }

    public function down(): void
    {
        $connection = DB::connection();
        if ($connection->getDriverName() !== 'sqlite') throw new RuntimeException('候选迁移仅接受 SQLite');
        $connection->transaction(function () use ($connection): void {
            if ($connection->table('v2_payment_attempt')->exists() || $connection->table('v2_billing_review')->exists()
                || $connection->table('v2_billing_outbox')->exists()
                || $connection->table('v2_commission_log')->whereNotNull('order_id')->exists()) {
                throw new RuntimeException('已有新增财务证据，禁止破坏性回滚，请保留表并人工对账');
            }
            $schema = $connection->getSchemaBuilder();
            $schema->table('v2_commission_log', function (Blueprint $table) {
                $table->dropUnique('billing_commission_order_level');
                $table->dropColumn(['order_id','level']);
            });
            $schema->drop('v2_payment_attempt');
            $schema->drop('v2_billing_review');
            $schema->drop('v2_billing_outbox');
            $schema->drop('v2_billing_mutex');
        });
    }
};
