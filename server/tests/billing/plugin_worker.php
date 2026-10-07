<?php

namespace App\Contracts {
    interface PaymentInterface { public function form(): array; public function pay($order): array; public function notify($params); }
}
namespace App\Exceptions { class ApiException extends \RuntimeException {} }
namespace App\Services\Plugin {
    abstract class AbstractPlugin {
        protected array $config = [];
        public function __construct(private string $code) {}
        public function setConfig(array $config): void { $this->config=$config; }
        public function getConfig(?string $key=null,$default=null): mixed { return $key===null?$this->config:($this->config[$key]??$default); }
        public function getPluginCode(): string { return $this->code; }
        protected function filter(string $hook,callable $callback,int $priority=20): void {}
    }
}
namespace App\Models {
    final class Record {
        public function __construct(private object $row) {}
        public function __get(string $name) { return $this->row->$name??null; }
        public function toArray(): array { return (array)$this->row; }
    }
    final class Payment {
        public static function find($id) { return $GLOBALS['db']->selectOne('SELECT * FROM v2_payment WHERE id=?',[$id]); }
    }
    final class Order {
        public static function find($id) {
            $row=$GLOBALS['db']->selectOne('SELECT * FROM v2_order WHERE id=?',[$id]);
            return $row?new Record($row):null;
        }
        public static function where($column,$value) {
            if ($column!=='trade_no') throw new \RuntimeException('测试查询字段不合法');
            return new class($value) {
                public function __construct(private string $tradeNo) {}
                public function first() {
                    $row=$GLOBALS['db']->selectOne('SELECT * FROM v2_order WHERE trade_no=?',[$this->tradeNo]);
                    return $row?new Record($row):null;
                }
            };
        }
    }
}
namespace {
    require __DIR__.'/PdoConnection.php';
    require __DIR__.'/../../patches/billing/overlay/app/Services/Billing/Atomic.php';
    require __DIR__.'/../../plugins/Fubei/Plugin.php';
    function app(string $key) {
        if ($key!=='db') throw new RuntimeException('测试容器仅允许数据库');
        return new class { public function connection() { return $GLOBALS['db']; } };
    }
    function config(string $key) { return ['payments.fubei.secrets.public_fixture'=>'public-fixture-secret-not-a-credential','payments.fubei.secrets.rotated_fixture'=>'public-rotated-fixture-not-a-credential'][$key]??null; }
    function request() {
        return new class {
            public $headers;
            public function __construct() { $this->headers=new class { public function get($key,$default='') { return 'application/x-www-form-urlencoded'; } }; }
            public function getContent() { return $GLOBALS['raw']; }
            public function getMethod() { return 'POST'; }
        };
    }
    class TestPlugin extends \Plugin\Fubei\Plugin {
        protected function client(): \Plugin\Fubei\Client {
            return new \Plugin\Fubei\Client($this->getConfig(),'public-fixture-secret-not-a-credential',function($url,$body) {
                $request=json_decode($body,true,32,JSON_THROW_ON_ERROR);
                $biz=json_decode($request['biz_content'],true,32,JSON_THROW_ON_ERROR);
                if (strlen($biz['merchant_order_sn'])!==32) throw new RuntimeException('平台外部号未映射32位');
                return json_encode(['result_code'=>200,'data'=>json_encode(['merchant_order_sn'=>$biz['merchant_order_sn'],'qrcode_url'=>'https://cashier.example.test/qr'])]);
            });
        }
    }
    $db=new PdoConnection($argv[1]);
    $operation=$argv[2]; $barrier=$argv[3]; $id=(int)$argv[4];
    touch($barrier.'.ready.'.getmypid());
    $deadline=microtime(true)+15;
    while(!is_file($barrier)) { if(microtime(true)>$deadline) throw new RuntimeException('测试屏障超时'); usleep(1000); }
    $plugin=new TestPlugin('fubei');
    $plugin->setConfig(['enabled'=>true,'enable'=>1,'id'=>5,'uuid'=>'PUBLIC-UUID','identity_mode'=>'merchant','app_id'=>'PUBLIC_FIXTURE','merchant_id'=>'123','store_id'=>'456','secret_ref'=>'public_fixture','gateway'=>'https://gateway.example.test/pay','gateway_hosts'=>'gateway.example.test','payment_hosts'=>'cashier.example.test','notify_hosts'=>'notify.example.test']);
    if (in_array($operation,['plugin_notify_rotated','plugin_pay_rotated'],true)) {
        $rotated=$plugin->getConfig();
        $rotated['app_id']='ROTATED_PUBLIC_ID';
        $rotated['merchant_id']='999'; $rotated['store_id']='888'; $rotated['secret_ref']='rotated_fixture';
        $plugin->setConfig($rotated);
    }
    $order=$db->selectOne('SELECT * FROM v2_order WHERE id=?',[$id]);
    if ($operation==='plugin_pay_rotated') {
        try { $plugin->pay(['trade_no'=>$order->trade_no,'total_amount'=>1000,'notify_url'=>'https://notify.example.test/callback']); }
        catch (\Throwable $e) { exit(0); }
        throw new RuntimeException('配置轮换允许覆盖未完成快照');
    } elseif ($operation==='plugin_pay') {
        $result=$plugin->pay(['trade_no'=>$order->trade_no,'total_amount'=>1000,'notify_url'=>'https://notify.example.test/callback']);
        if ($result['type']!==0) throw new RuntimeException('二维码适配结果错误');
    } elseif (in_array($operation,['plugin_notify','plugin_notify_rotated'],true)) {
        $attempt=$db->selectOne('SELECT * FROM v2_payment_attempt WHERE order_id=?',[$id]);
        $params=['result_code'=>'200','result_message'=>' 成功 ','data'=>json_encode(['merchant_order_sn'=>$attempt->external_no,'order_sn'=>'PLUGIN_PROVIDER','order_status'=>'SUCCESS','pay_type'=>'wxpay','uid'=>(int)$attempt->merchant_id,'store_id'=>(int)$attempt->store_id,'total_amount'=>10],JSON_UNESCAPED_UNICODE)];
        $params['sign']=\Plugin\Fubei\Signature::sign($params,'public-fixture-secret-not-a-credential');
        $raw=http_build_query($params);
        // 传入的中间件参数故意损坏；真实代码必须从 raw 正文获取验签数据。
        $result=$plugin->notify(['result_message'=>'成功','data'=>null]);
        if (!is_array($result) || $result['trade_no']!==$order->trade_no || strlen($result['trade_no'])!==36) throw new RuntimeException('回调未映射原36位订单或受中间件影响');
    } else throw new RuntimeException('未知插件测试操作');
}
