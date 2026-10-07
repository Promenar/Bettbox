<?php

// 使用真实 SQLite PDO 连接，仅适配 Laravel connection 的方法形状。
final class PdoConnection
{
    public PDO $pdo;
    private int $depth = 0;
    public function __construct(string $path)
    {
        $this->pdo = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $this->pdo->exec('PRAGMA busy_timeout=10000');
        $this->pdo->exec('PRAGMA foreign_keys=ON');
    }
    public function getDriverName(): string { return 'sqlite'; }
    public function transaction(callable $action, int $attempts = 1)
    {
        if ($this->depth !== 0) throw new RuntimeException('测试入口不允许嵌套');
        for ($try = 0; $try < $attempts; $try++) {
            $this->pdo->beginTransaction();
            $this->depth++;
            try {
                $result = $action();
                $this->pdo->commit();
                $this->depth--;
                return $result;
            } catch (Throwable $e) {
                if ($this->pdo->inTransaction()) $this->pdo->rollBack();
                $this->depth--;
                if (!$e instanceof PDOException || !in_array($e->errorInfo[1] ?? null, [5,6], true) || $try + 1 === $attempts) throw $e;
                usleep(10000);
            }
        }
    }
    public function affectingStatement(string $sql, array $bindings = []): int
    {
        $statement = $this->pdo->prepare($sql);
        $statement->execute($bindings);
        return $statement->rowCount();
    }
    public function insert(string $sql, array $bindings = []): bool
    {
        $statement = $this->pdo->prepare($sql);
        return $statement->execute($bindings);
    }
    public function select(string $sql, array $bindings = []): array
    {
        $statement = $this->pdo->prepare($sql);
        $statement->execute($bindings);
        return $statement->fetchAll(PDO::FETCH_OBJ);
    }
    public function selectOne(string $sql, array $bindings = []): ?object
    {
        $statement = $this->pdo->prepare($sql);
        $statement->execute($bindings);
        return $statement->fetch(PDO::FETCH_OBJ) ?: null;
    }
}
