<?php

namespace App\Contracts {
    interface PaymentInterface {
        public function form(): array;
        public function pay($order): array;
        public function notify($params);
    }
}

namespace App\Exceptions {
    class ApiException extends \RuntimeException {}
}

namespace App\Services\Plugin {
    abstract class AbstractPlugin {
        protected array $config = [];
        public $registeredFilter;
        public function __construct(private string $pluginCode) {}
        public function setConfig(array $config): void { $this->config = $config; }
        public function getConfig(?string $key = null, $default = null): mixed { return $key === null ? $this->config : ($this->config[$key] ?? $default); }
        public function getPluginCode(): string { return $this->pluginCode; }
        protected function filter(string $hook, callable $callback, int $priority = 20): void { $this->registeredFilter = $callback; }
    }
}

namespace App\Models {
    class Payment {
        public static ?object $fixture = null;
        public static function find($id) { return self::$fixture && self::$fixture->id == $id ? self::$fixture : null; }
    }
    class Order {
        public static ?array $fixture = null;
        public static function where($field, $value) {
            return new class($value) {
                public function __construct(private $tradeNo) {}
                public function first() {
                    if (!Order::$fixture || Order::$fixture['trade_no'] !== $this->tradeNo) return null;
                    return new class {
                        public function toArray(): array { return Order::$fixture; }
                    };
                }
            };
        }
    }
}

namespace {
    function request() {
        return new class {
            public $headers;
            public function __construct() {
                $this->headers = new class { public function get($key, $default = '') { return 'application/x-www-form-urlencoded'; } };
            }
            public function getContent() { return $GLOBALS['rawNotificationBody']; }
            public function getMethod() { return 'POST'; }
        };
    }
    // 只允许读取公开 fixture 路径，不启动 Laravel、不访问生产配置。
    function config(string $key) {
        return $key === 'payments.fubei.secrets.public_fixture' ? $GLOBALS['fixture']['secret'] : null;
    }
    require_once __DIR__ . '/../../plugins/Fubei/Plugin.php';

    $plugin = new \Plugin\Fubei\Plugin('fubei');
    $plugin->boot();
    check(($plugin->registeredFilter)([]) === [], '候选默认不注册支付');
    check($plugin->notify($params) === false, '候选默认拒绝通知');
    rejects(fn() => $plugin->pay($pay), '候选默认拒绝下单且不联网');
    $metadata = json_decode(file_get_contents(__DIR__ . '/../../plugins/Fubei/config.json'), true, 32, JSON_THROW_ON_ERROR);
    check($metadata['config']['enabled']['default'] === false, '插件元数据默认关闭');

    $adapterConfig = $config + ['enabled' => true, 'enable' => 1, 'uuid' => 'PUBLIC-UUID', 'secret_ref' => 'public_fixture'];
    $plugin->setConfig($adapterConfig);
    $GLOBALS['rawNotificationBody'] = http_build_query($params);
    \App\Models\Payment::$fixture = (object) ['id' => 5, 'enable' => 1, 'payment' => 'Fubei', 'uuid' => 'PUBLIC-UUID'];
    \App\Models\Order::$fixture = $order;
    check($plugin->notify($params) === false, '未安装账务服务适配器失败关闭');
    check($plugin->notify(['data' => null, 'result_message' => '已变换']) === false, '缺账务服务不回退变换参数');
    $GLOBALS['rawNotificationBody'] = http_build_query($rawSpaced);
    check($plugin->notify([]) === false, '缺账务服务拒绝原始空格通知');
    $GLOBALS['rawNotificationBody'] = http_build_query($params) . '&data=x';
    check($plugin->notify($params) === false, '适配器拒绝重复表单字段');
    $GLOBALS['rawNotificationBody'] = http_build_query($params);
    \App\Models\Order::$fixture = null;
    check($plugin->notify($params) === false, '未知订单不能成功通知');
    \App\Models\Order::$fixture = $order;
    \App\Models\Payment::$fixture->payment = 'EPay';
    check($plugin->notify($params) === false, '路由支付方法归属拒绝');
    \App\Models\Payment::$fixture->payment = 'Fubei';
    \App\Models\Payment::$fixture->uuid = 'OTHER';
    check($plugin->notify($params) === false, '路由 UUID 归属拒绝');
    \App\Models\Payment::$fixture->uuid = 'PUBLIC-UUID';
    $plugin->setConfig(array_replace($adapterConfig, ['secret_ref' => 'missing_fixture']));
    check($plugin->notify($params) === false, '缺失服务器密钥拒绝');
}
