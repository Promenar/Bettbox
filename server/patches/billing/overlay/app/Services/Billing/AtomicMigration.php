<?php

namespace App\Services\Billing;

use Illuminate\Database\Connection;
use Illuminate\Database\Migrations\Migrator;
use RuntimeException;

final class AtomicMigration
{
    public const NAME = '2026_10_07_000001_add_billing_atomicity';
    public const RELATIVE_PATH = 'database/migrations/'.self::NAME.'.php';

    public static function perform(Connection $connection, Migrator $migrator, string $path, bool $rollback = false): array
    {
        if ($connection->getDriverName()!=='sqlite' || $connection->transactionLevel()!==0) {
            throw new RuntimeException('账务迁移仅接受独立 SQLite 事务');
        }
        if (!is_file($path) || realpath($path)!==$path || basename($path)!==self::NAME.'.php'
            || $migrator->getMigrationFiles([$path])!==[self::NAME=>$path]) {
            throw new RuntimeException('账务迁移路径不匹配');
        }
        $name = $connection->getName();
        if (!is_string($name) || $name==='' || $migrator->resolveConnection($name)!==$connection) {
            throw new RuntimeException('账务迁移连接不匹配');
        }
        $operation = function () use ($migrator,$path,$rollback): array {
            $repository = $migrator->getRepository();
            if (!$repository->repositoryExists()) throw new RuntimeException('迁移仓库不存在，请核对部署来源');
            $before = $repository->getRan();
            if (count(array_keys($before,self::NAME,true))>1) throw new RuntimeException('账务迁移记录重复');
            if ($rollback) {
                $last = $repository->getLast();
                if (count($last)!==1 || $last[0]->migration!==self::NAME) {
                    throw new RuntimeException('最后迁移批次不属于账务候选');
                }
                $migrator->rollback([$path],['step'=>1]);
            } else {
                $migrator->run([$path],['step'=>true]);
            }
            $after = $repository->getRan();
            if (in_array(self::NAME,$after,true)===$rollback) throw new RuntimeException('账务迁移记录未确认');
            return ['operation'=>$rollback?'down':'up','completed'=>true,'changed'=>$before!==$after];
        };
        // 外层事务包括 Migrator 的成功记录，迁移内部事务成为同连接 savepoint。
        return $migrator->usingConnection($name,fn()=>$connection->transaction($operation));
    }
}
