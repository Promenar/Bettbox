<?php
/** 真实 Laravel 迁移类验收；只接受调用方已经隔离的空数据库连接。 */
function fixtureMigrationLifecycle($db, string $candidate): void
{
    $pdo = $db->getPdo();
    $tables = ['v2_payment_attempt','v2_billing_review','v2_billing_outbox','v2_billing_mutex',
        'v2_commission_log','v2_order','v2_payment','fixture_migrations'];
    $schema = $db->getSchemaBuilder();
    foreach ($tables as $table) fixtureCheck(!$schema->hasTable($table),'migration_empty_'.$table);
    // 两个输入均登记摘要；迁移类按自身目录加载冻结的 SQL 文件。
    fixtureFile($candidate,'server/patches/billing/overlay/database/migrations/billing_atomic_schema.sql');
    $migrationPath = fixtureFile($candidate,'server/patches/billing/overlay/database/migrations/2026_10_07_000001_add_billing_atomicity.php');
    $migration = require $migrationPath;
    fixtureCheck($migration instanceof Illuminate\Database\Migrations\Migration,'migration_actual_class');
    $reset = static function () use ($pdo, $tables): void {
        foreach ($tables as $table) $pdo->exec('DROP TABLE IF EXISTS '.$table);
    };
    $base = static function () use ($pdo): void {
        $pdo->exec('CREATE TABLE v2_order(id INTEGER PRIMARY KEY)');
        $pdo->exec('CREATE TABLE v2_payment(id INTEGER PRIMARY KEY)');
        $pdo->exec('CREATE TABLE v2_commission_log(id INTEGER PRIMARY KEY,invite_user_id INTEGER,user_id INTEGER,trade_no TEXT,order_amount INTEGER,get_amount INTEGER,created_at INTEGER,updated_at INTEGER)');
        $pdo->exec('INSERT INTO v2_order(id) VALUES(1)');
        $pdo->exec('INSERT INTO v2_payment(id) VALUES(1)');
        $pdo->exec("INSERT INTO v2_commission_log VALUES(1,2,1,'PUBLIC_HISTORY',1000,100,1,1)");
    };
    $snapshot = static function () use ($pdo, $schema, $tables): string {
        $value = [$pdo->query('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')->fetchAll(PDO::FETCH_ASSOC)];
        foreach ($tables as $table) {
            if ($schema->hasTable($table)) $value[$table] = $pdo->query('SELECT * FROM '.$table.' ORDER BY 1')->fetchAll(PDO::FETCH_ASSOC);
        }
        return hash('sha256',json_encode($value,JSON_THROW_ON_ERROR));
    };
    $rejectUnchanged = static function (callable $operation, string $label, string $message) use ($snapshot): void {
        $before = $snapshot();
        $rejected = false;
        try { $operation(); } catch (RuntimeException $error) {
            if (get_class($error)!==RuntimeException::class || $error->getMessage()!==$message) throw $error;
            $rejected = true;
        }
        fixtureCheck($rejected && $snapshot()===$before,$label);
    };
    try {
        $base();
        foreach ([new RuntimeException('PUBLIC_UNRELATED_FAILURE'),
            new UnexpectedValueException('计费表已存在，请核对迁移来源')] as $unexpected) {
            $caught = null;
            try {
                $rejectUnchanged(fn()=>throw $unexpected,'migration_wrong_exception_must_not_pass','计费表已存在，请核对迁移来源');
            } catch (Throwable $error) { $caught = $error; }
            fixtureCheck($caught===$unexpected,'migration_unexpected_'.get_class($unexpected).'_propagated');
        }
        $history = $db->table('v2_commission_log')->first();
        $migration->up();
        foreach (array_slice($tables,0,4) as $table) fixtureCheck($schema->hasTable($table),'migration_up_'.$table);
        $migrated = $db->table('v2_commission_log')->first();
        fixtureCheck($migrated->order_id===null && $migrated->level===null
            && (array)$history===array_diff_key((array)$migrated,['order_id'=>true,'level'=>true]),'migration_history_preserved');
        fixtureCheck($pdo->query('PRAGMA foreign_key_check')->fetchAll()===[],'migration_foreign_keys_valid');
        $migration->down();
        fixtureCheck((array)$db->table('v2_commission_log')->first()===(array)$history
            && !$schema->hasColumn('v2_commission_log','order_id') && !$schema->hasColumn('v2_commission_log','level'),'migration_empty_down_preserves_history');
        foreach (array_slice($tables,0,4) as $table) fixtureCheck(!$schema->hasTable($table),'migration_down_'.$table);
        $migration->up();
        fixtureCheck($db->table('v2_commission_log')->count()===1,'migration_up_after_empty_down');
        $reset();

        foreach (array_slice($tables,0,4) as $table) {
            $base();
            $pdo->exec('CREATE TABLE '.$table.'(id INTEGER PRIMARY KEY,marker TEXT)');
            $db->table($table)->insert(['id'=>1,'marker'=>'PUBLIC_COLLISION']);
            $rejectUnchanged(fn()=>$migration->up(),'migration_collision_'.$table,'计费表已存在，请核对迁移来源');
            $reset();
        }
        foreach (['order_id','level'] as $column) {
            $base();
            $pdo->exec('ALTER TABLE v2_commission_log ADD COLUMN '.$column.' INTEGER NULL');
            $rejectUnchanged(fn()=>$migration->up(),'migration_collision_'.$column,'佣金列已存在，请核对迁移来源');
            $reset();
        }

        foreach (['attempt','review','outbox','commission'] as $evidence) {
            $base();
            $migration->up();
            switch ($evidence) {
                case 'attempt':
                    $db->table('v2_payment_attempt')->insert(['order_id'=>1,'payment_id'=>1,'external_no'=>str_repeat('A',32),
                        'identity_mode'=>'merchant','identity_key'=>'PUBLIC_ID','secret_ref'=>'public_fixture',
                        'provider_scope'=>'PUBLIC_SCOPE','merchant_id'=>1,'store_id'=>1,'expected_cents'=>1000,'created_at'=>1]);
                    break;
                case 'review':
                    $db->table('v2_billing_review')->insert(['order_id'=>1,'category'=>'PUBLIC_REVIEW','reason'=>'PUBLIC_TEST','created_at'=>1]);
                    break;
                case 'outbox':
                    $db->table('v2_billing_outbox')->insert(['event_id'=>'PUBLIC_EVENT','order_id'=>1,'event_type'=>'payment.notify.success','created_at'=>1]);
                    break;
                case 'commission':
                    $db->table('v2_commission_log')->insert(['id'=>2,'order_id'=>1,'level'=>0,'trade_no'=>'PUBLIC_NEW','get_amount'=>100]);
                    break;
            }
            $rejectUnchanged(fn()=>$migration->down(),'migration_evidence_'.$evidence.'_retained','已有新增财务证据，禁止破坏性回滚，请保留表并人工对账');
            $reset();
        }
        $base();
        $repository = new Illuminate\Database\Migrations\DatabaseMigrationRepository(Illuminate\Support\Facades\DB::getFacadeRoot(),'fixture_migrations');
        $repository->createRepository();
        $migrator = new Illuminate\Database\Migrations\Migrator($repository,Illuminate\Support\Facades\DB::getFacadeRoot(),new Illuminate\Filesystem\Filesystem(),app('events'));
        fixtureCheck($migrator->getMigrationFiles([$migrationPath])===[basename($migrationPath,'.php')=>$migrationPath],'migration_migrator_exact_path');
        $migrator->run([$migrationPath]);
        fixtureCheck($repository->getRan()===[basename($migrationPath,'.php')]
            && (int)$db->table('fixture_migrations')->value('batch')===1,'migration_migrator_batch_recorded');
        $before = $snapshot();
        $migrator->run([$migrationPath]);
        fixtureCheck($snapshot()===$before,'migration_migrator_repeat_noop');
        $injectDown = false;
        $downFault = new RuntimeException('PUBLIC_DOWN_FAILURE');
        $db->listen(static function ($query) use (&$injectDown,$downFault): void {
            if ($injectDown && preg_match('/\bdrop\s+table\s+.*v2_billing_outbox/i',$query->sql)) {
                $injectDown = false;
                throw $downFault;
            }
        });
        $before = $snapshot();
        $caught = null;
        $injectDown = true;
        try { $migrator->rollback([$migrationPath]); } catch (Throwable $error) { $caught = $error; }
        finally { $injectDown = false; }
        fixtureCheck($caught===$downFault && $snapshot()===$before,'migration_migrator_down_failure_atomic');
        $migrator->rollback([$migrationPath]);
        fixtureCheck($repository->getRan()===[] && $db->table('v2_commission_log')->count()===1
            && !$schema->hasColumn('v2_commission_log','order_id'),'migration_migrator_rollback_history_preserved');
        // 缺佣金表在多语句 SQL 后段失败，必须撤销已创建表且不登记成功批次。
        $pdo->exec('DROP TABLE v2_commission_log');
        $before = $snapshot();
        $failed = false;
        try { $migrator->run([$migrationPath]); } catch (Illuminate\Database\QueryException $error) { $failed = true; }
        fixtureCheck($failed && $snapshot()===$before && $repository->getRan()===[],'migration_migrator_failure_atomic');
    } finally {
        // 只回收已声明为空的公开临时库；不作用于任何生产连接。
        $reset();
    }
    fixtureCheck($db->getPdo()===$pdo,'migration_same_isolated_connection');
}
