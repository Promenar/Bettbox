<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        if (DB::connection()->getDriverName() !== 'sqlite') throw new RuntimeException('候选迁移仅接受 SQLite');
        foreach (['v2_billing_mutex','v2_payment_attempt','v2_billing_review','v2_billing_outbox'] as $table) {
            if (Schema::hasTable($table)) throw new RuntimeException('计费表已存在，请核对迁移来源');
        }
        if (Schema::hasColumn('v2_commission_log','order_id') || Schema::hasColumn('v2_commission_log','level')) throw new RuntimeException('佣金列已存在，请核对迁移来源');
        DB::unprepared(file_get_contents(__DIR__ . '/billing_atomic_schema.sql'));
    }

    public function down(): void
    {
        if (DB::table('v2_payment_attempt')->exists() || DB::table('v2_billing_review')->exists()
            || DB::table('v2_billing_outbox')->exists()
            || DB::table('v2_commission_log')->whereNotNull('order_id')->exists()) {
            throw new RuntimeException('已有新增财务证据，禁止破坏性回滚，请保留表并人工对账');
        }
        Schema::table('v2_commission_log', function (Blueprint $table) {
            $table->dropUnique('billing_commission_order_level');
            $table->dropColumn(['order_id','level']);
        });
        Schema::drop('v2_payment_attempt');
        Schema::drop('v2_billing_review');
        Schema::drop('v2_billing_outbox');
        Schema::drop('v2_billing_mutex');
    }
};
