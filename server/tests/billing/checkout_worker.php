<?php

// 执行实际 checkout 控制器；仅模型/请求外壳适配，持久化使用真实独立 SQLite PDO。
namespace App\Exceptions { class ApiException extends \RuntimeException {} }
namespace App\Http\Controllers {
    class Controller { protected function fail($error) { return ['failed'=>$error]; } }
}
namespace Illuminate\Http {
    class Request {
        public function __construct(private array $values) {}
        public function input($key) { return $this->values[$key]??null; }
        public function user() { return (object)['id'=>1]; }
    }
}
namespace Illuminate\Support\Facades {
    class DB { public static function connection() { return $GLOBALS['db']; } }
}
namespace App\Models {
    class CheckoutOrder {
        public function __construct(private object $row) {}
        public function __get($key) { return $this->row->$key??null; }
        public function __set($key,$value): void { $this->row->$key=$value; }
        public function __isset($key): bool { return isset($this->row->$key); }
        public function save(): bool {
            return $GLOBALS['db']->affectingStatement('UPDATE v2_order SET handling_amount=?,payment_id=? WHERE id=?',[$this->row->handling_amount,$this->row->payment_id,$this->row->id])===1;
        }
    }
    class CheckoutQuery {
        private array $clauses=[];
        private array $bindings=[];
        public function where($key,$value): self {
            if (!in_array($key,['trade_no','user_id','status'],true)) throw new \RuntimeException('测试查询字段拒绝');
            $this->clauses[]=$key.'=?'; $this->bindings[]=$value;
            return $this;
        }
        public function first() {
            $row=$GLOBALS['db']->selectOne('SELECT * FROM v2_order WHERE '.implode(' AND ',$this->clauses),$this->bindings);
            return $row?new CheckoutOrder($row):null;
        }
    }
    class Order {
        const STATUS_PENDING=0;
        public static function where($key,$value) { return (new CheckoutQuery())->where($key,$value); }
        public static function find($id) {
            $row=$GLOBALS['db']->selectOne('SELECT * FROM v2_order WHERE id=?',[$id]);
            return $row?new CheckoutOrder($row):null;
        }
    }
    class Payment { public static function find($id) { return $GLOBALS['db']->selectOne('SELECT * FROM v2_payment WHERE id=?',[$id]); } }
}
namespace App\Services {
    class PaymentService {
        public function __construct($method,$id) {}
        public function pay($order): array {
            // 记录实际调用次数和金额；测试绝不发网络或收款。
            $GLOBALS['db']->insert('INSERT INTO test_gateway_call(trade_no,amount) VALUES(?,?)',[$order['trade_no'],$order['total_amount']]);
            return ['type'=>0,'data'=>'PUBLIC_CHECKOUT_FIXTURE'];
        }
    }
}
namespace {
    require __DIR__.'/PdoConnection.php';
    require __DIR__.'/../../patches/billing/overlay/app/Services/Billing/Atomic.php';
    require __DIR__.'/../../patches/billing/overlay/app/Http/Controllers/V1/User/OrderController.php';
    function __($value) { return $value; }
    function response($value) { return $value; }
    $db=new PdoConnection($argv[1]);
    $operation=$argv[2]; $barrier=$argv[3]; $id=(int)$argv[4];
    touch($barrier.'.ready.'.getmypid());
    $deadline=microtime(true)+15;
    while(!is_file($barrier)) { if(microtime(true)>$deadline) throw new RuntimeException('测试屏障超时'); usleep(1000); }
    $order=$db->selectOne('SELECT trade_no FROM v2_order WHERE id=?',[$id]);
    $request=new \Illuminate\Http\Request(['trade_no'=>$order->trade_no,'method'=>$operation==='checkout_negative'?6:7]);
    $result=(new \App\Http\Controllers\V1\User\OrderController())->checkout($request);
    if ($operation==='checkout_negative' && !isset($result['failed'])) throw new RuntimeException('负手续费 checkout 未拒绝');
    if ($operation==='checkout_positive' && ($result['type']??null)!==0) throw new RuntimeException('正常旧插件 checkout 兼容失败');
}
