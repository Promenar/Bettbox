<?php

namespace Plugin\Fubei;

use App\Contracts\PaymentInterface;
use App\Exceptions\ApiException;
use App\Models\Order;
use App\Models\Payment;
use App\Services\Plugin\AbstractPlugin;

require_once __DIR__ . '/Signature.php';
require_once __DIR__ . '/Amount.php';
require_once __DIR__ . '/Client.php';
require_once __DIR__ . '/Notification.php';
require_once __DIR__ . '/RawNotification.php';
require_once __DIR__ . '/JsonAmount.php';

class Plugin extends AbstractPlugin implements PaymentInterface
{
    public function boot(): void
    {
        $this->filter('available_payment_methods', function (array $methods): array {
            // 插件管理器与支付方式均需显式启用，候选默认不暴露支付入口。
            if ($this->getConfig('enabled', false) === true) {
                $methods['Fubei'] = ['name' => '付呗', 'icon' => '💳', 'plugin_code' => $this->getPluginCode(), 'type' => 'plugin'];
            }
            return $methods;
        });
    }

    public function form(): array
    {
        $fields = [
            'enabled' => ['启用候选支付', '服务器并发到账和返佣验收通过后才允许启用'],
            'identity_mode' => ['接入身份', 'merchant 为商户级，vendor 为服务商级'],
            'app_id' => ['商户开放平台标识', '商户级填写，与 vendor_sn 二选一'],
            'vendor_sn' => ['服务商开放平台标识', '服务商级填写，与 app_id 二选一'],
            'merchant_id' => ['付呗商户编号', '两种身份均需配置用于回调归属核对，商户级下单不发送此字段'],
            'store_id' => ['付呗门店编号', '必须属于配置的商户'],
            'secret_ref' => ['服务器密钥引用', '只填写服务器安全配置中的引用名，禁止填写密钥原文'],
            'gateway' => ['付呗 HTTPS 网关', '由官方确认，完整 URL；不自动选择网关'],
            'gateway_hosts' => ['网关主机白名单', '精确域名，逗号分隔；不支持通配符或 IP'],
            'payment_hosts' => ['支付二维码主机白名单', '官方确认的精确支付域名，逗号分隔'],
            'notify_hosts' => ['回调主机白名单', '已验证可达的 HTTPS 回调域名，逗号分隔'],
            'expired_time' => ['二维码有效秒数', '1 至 1800，默认 600'],
        ];
        $form = [];
        foreach ($fields as $key => [$label, $description]) {
            $form[$key] = ['type' => $key === 'enabled' ? 'boolean' : 'string', 'label' => $label, 'description' => $description,
                'default' => $key === 'enabled' ? false : ($key === 'expired_time' ? '600' : '')];
        }
        return $form;
    }

    public function pay($order): array
    {
        try {
            $this->requireEnabled();
            $this->requireBilling();
            $internal = Order::where('trade_no', $order['trade_no'] ?? '')->first();
            if (!$internal || (string)$internal->payment_id !== (string)$this->getConfig('id')) throw new \RuntimeException('订单支付归属不匹配');
            $attempt = \App\Services\Billing\Atomic::attempt(app('db')->connection(), (int)$internal->id, $this->snapshot($order['total_amount'] ?? null));
            $order['trade_no'] = $attempt->external_no;
            $client = $this->client();
            return ['type' => 0, 'data' => $client->createQr($order)];
        } catch (\Throwable $e) {
            // 上层会记录异常，因此不带入密钥、签名、请求或响应正文。
            throw new ApiException('付呗支付未完成，请检查服务器配置并核对原订单');
        }
    }

    public function notify($params): array|bool
    {
        try {
            $this->requireEnabled();
            $this->requireBilling();
            $request = request();
            $params = RawNotification::parse($request->getContent(), $request->headers->get('Content-Type', ''), $request->getMethod());
            $db = app('db')->connection();
            // 仅用未认证的有界订单标识定位快照；任何到账字段均在快照密钥验签后使用。
            $routing = json_decode($params['data'],true,32,JSON_THROW_ON_ERROR);
            $external = is_array($routing) ? ($routing['merchant_order_sn'] ?? null) : null;
            if (!is_string($external) || !preg_match('/^[a-f0-9]{32}$/D',$external)) return false;
            $attempt = $db->selectOne('SELECT * FROM v2_payment_attempt WHERE external_no=?', [$external]);
            if (!$attempt || (string)$attempt->payment_id !== (string)$this->getConfig('id')) return false;
            $data = Notification::decode($params,$this->secret($attempt->secret_ref));
            $scope = hash('sha256',json_encode([$attempt->identity_mode,$attempt->identity_key,(string)$attempt->merchant_id]));
            if ($scope !== $attempt->provider_scope || (string)($data['uid'] ?? '') !== (string)$attempt->merchant_id || (string)($data['store_id'] ?? '') !== (string)$attempt->store_id
                || !in_array($data['pay_type'] ?? null,['wxpay','alipay'],true)) return false;
            $transitioned = false;
            if (!\App\Services\Billing\Atomic::settleAttempt($db,$attempt->external_no,$data['order_sn'],$scope,(int)$attempt->merchant_id,(int)$attempt->store_id,Amount::fromYuan($data['total_amount']),function () use (&$transitioned) { $transitioned = true; })) return false;
            $internal = Order::find($attempt->order_id);
            if (!$internal) return false;
            // 已在 SQLite 写事务内到账；通用控制器复用同流水完成开通或补偿。
            return ['trade_no'=>$internal->trade_no,'callback_no'=>$data['order_sn'],'custom_result'=>'success','billing_transitioned'=>$transitioned];
        } catch (\Throwable $e) {
            return false;
        }
    }

    private function requireEnabled(): void
    {
        if ($this->getConfig('enabled', false) !== true || !in_array($this->getConfig('enable', false), [true, 1, '1'], true)) {
            throw new \RuntimeException('付呗候选支付未启用');
        }
        $payment = Payment::find($this->getConfig('id'));
        if (!$payment || !$payment->enable || $payment->payment !== 'Fubei'
            || !is_string($this->getConfig('uuid')) || $payment->uuid !== $this->getConfig('uuid')) {
            throw new \RuntimeException('付呗支付配置归属不匹配');
        }
    }

    private function requireBilling(): void
    {
        if (!class_exists(\App\Services\Billing\Atomic::class)) throw new \RuntimeException('付呗账务事务服务未安装');
        $db = app('db')->connection();
        if ($db->getDriverName() !== 'sqlite') throw new \RuntimeException('付呗账务数据库目标未验收');
        // 查询不存在的表会抛异常并失败关闭，不创建、不迁移、不回退。
        if (!$db->selectOne('SELECT id FROM v2_billing_mutex WHERE id=1')) throw new \RuntimeException('付呗账务迁移未完成');
        $db->selectOne('SELECT id FROM v2_payment_attempt LIMIT 1');
    }

    private function snapshot(mixed $cents): array
    {
        $identity = Client::identity($this->getConfig());
        return ['payment_id'=>$this->getConfig('id'),'identity_mode'=>$this->getConfig('identity_mode'),
            'identity_key'=>array_values($identity)[0],'merchant_id'=>$this->getConfig('merchant_id'),
            'store_id'=>$this->getConfig('store_id'),'expected_cents'=>Amount::cents($cents),'secret_ref'=>$this->getConfig('secret_ref')];
    }

    private function secret(?string $reference = null): string
    {
        $reference = $reference ?? $this->getConfig('secret_ref', '');
        if (!is_string($reference) || !preg_match('/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/D', $reference)) {
            throw new \RuntimeException('服务器密钥引用未配置');
        }
        $secret = config('payments.fubei.secrets.' . $reference);
        if (!is_string($secret) || $secret === '') {
            throw new \RuntimeException('服务器密钥不可用');
        }
        return $secret;
    }

    protected function client(): Client
    {
        return new Client($this->getConfig(), $this->secret());
    }
}
