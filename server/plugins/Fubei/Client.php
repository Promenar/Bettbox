<?php

namespace Plugin\Fubei;

final class Client
{
    private $transport;
    private array $config;
    private string $secret;

    public function __construct(array $config, string $secret, ?callable $transport = null)
    {
        self::identity($config);
        self::httpsUrl($config['gateway'] ?? '', $config['gateway_hosts'] ?? '');
        if ($secret === '') {
            throw new \InvalidArgumentException('付呗服务器密钥未配置');
        }
        $this->config = $config;
        $this->secret = $secret;
        $this->transport = $transport ?? [self::class, 'send'];
    }

    public static function identity(array $config): array
    {
        $mode = $config['identity_mode'] ?? '';
        $field = match ($mode) {
            'merchant' => 'app_id',
            'vendor' => 'vendor_sn',
            default => throw new \InvalidArgumentException('付呗接入身份未配置'),
        };
        $identity = $config[$field] ?? '';
        if (!is_string($identity) || !preg_match('/^[a-zA-Z0-9_-]{1,32}$/D', $identity)
            || !empty($config[$field === 'app_id' ? 'vendor_sn' : 'app_id'])) {
            throw new \InvalidArgumentException('付呗接入标识必须按身份二选一');
        }
        // 商户级请求不发送 merchant_id，但仍需配置用于校对回调 uid。
        foreach (['merchant_id', 'store_id'] as $key) {
            if (!preg_match('/^[1-9][0-9]{0,10}$/D', (string) ($config[$key] ?? ''))) {
                throw new \InvalidArgumentException('付呗商户或门店编号未配置');
            }
        }
        return [$field => $identity];
    }

    public static function httpsUrl(mixed $url, mixed $allowedHosts): string
    {
        if (!is_string($url) || !is_string($allowedHosts) || preg_match('/[\x00-\x20\x7f\\\\]/', $url)) {
            throw new \InvalidArgumentException('支付地址格式不合法');
        }
        $parts = parse_url($url);
        $host = strtolower($parts['host'] ?? '');
        $allowed = array_filter(array_map('trim', explode(',', strtolower($allowedHosts))));
        if (!$parts || ($parts['scheme'] ?? '') !== 'https' || isset($parts['user']) || isset($parts['pass'])
            || isset($parts['fragment']) || (isset($parts['port']) && $parts['port'] !== 443)
            || !preg_match('/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/D', $host)
            || !in_array($host, $allowed, true)) {
            throw new \InvalidArgumentException('支付地址不在明确配置的 HTTPS 主机白名单中');
        }
        return $url;
    }

    public function createQr(array $order): string
    {
        $tradeNo = $order['trade_no'] ?? '';
        if (!is_string($tradeNo) || !preg_match('/^[a-zA-Z0-9_-]{1,32}$/D', $tradeNo)) {
            throw new \InvalidArgumentException('外部订单号格式不合法');
        }
        $notify = $order['notify_url'] ?? '';
        self::httpsUrl($notify, $this->config['notify_hosts'] ?? '');
        if (strlen($notify) > 255 || isset(parse_url($notify)['query'])) {
            throw new \InvalidArgumentException('回调地址必须不含查询参数且不超过255字节');
        }
        $expiry = $this->config['expired_time'] ?? 600;
        if (!preg_match('/^[1-9][0-9]{0,3}$/D', (string) $expiry) || (int) $expiry > 1800) {
            throw new \InvalidArgumentException('二维码有效期必须为1至1800秒');
        }
        $biz = [
            'merchant_order_sn' => $tradeNo,
            'store_id' => (int) $this->config['store_id'],
            'expired_time' => (int) $expiry,
            'notify_url' => $notify,
            'body' => '订阅订单',
        ];
        if ($this->config['identity_mode'] === 'vendor') {
            $biz['merchant_id'] = (int) $this->config['merchant_id'];
        }
        // 金额按精确十进制数字写入 JSON，避免 float 序列化改变小数。
        $bizJson = json_encode($biz, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        $bizJson = substr($bizJson, 0, -1) . ',"total_amount":' . Amount::toYuan($order['total_amount'] ?? null) . '}';
        $request = self::identity($this->config) + [
            'method' => 'fbpay.fixed.qrcode.create',
            'format' => 'json',
            'sign_method' => 'md5',
            'version' => '1.0',
            'nonce' => bin2hex(random_bytes(16)),
            'biz_content' => $bizJson,
        ];
        $request['sign'] = Signature::sign($request, $this->secret);
        $raw = ($this->transport)($this->config['gateway'], json_encode($request, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
        if (!is_string($raw) || strlen($raw) > 1048576) {
            throw new \RuntimeException('付呗响应格式或长度不合法');
        }
        $response = json_decode($raw, true, 32, JSON_THROW_ON_ERROR);
        if (!is_array($response) || !in_array($response['result_code'] ?? null, [200, '200'], true)) {
            throw new \RuntimeException('付呗未接受下单，请核对订单后处理');
        }
        $data = $response['data'] ?? null;
        if (!is_string($data)) {
            throw new \RuntimeException('付呗响应业务参数格式不合法');
        }
        $data = json_decode($data, true, 32, JSON_THROW_ON_ERROR);
        if (!is_array($data) || ($data['merchant_order_sn'] ?? null) !== $tradeNo) {
            throw new \RuntimeException('付呗响应订单号不匹配');
        }
        return self::httpsUrl($data['qrcode_url'] ?? '', $this->config['payment_hosts'] ?? '');
    }

    private static function send(string $url, string $body): string
    {
        if (!function_exists('curl_init')) {
            throw new \RuntimeException('服务器缺少 cURL 扩展');
        }
        $handle = curl_init($url);
        $response = '';
        curl_setopt_array($handle, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $body,
            CURLOPT_HTTPHEADER => ['Content-Type: application/json; charset=utf-8'],
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT => 15,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_PROTOCOLS => CURLPROTO_HTTPS,
            CURLOPT_WRITEFUNCTION => static function ($curl, string $chunk) use (&$response): int {
                if (strlen($response) + strlen($chunk) > 1048576) return 0;
                $response .= $chunk;
                return strlen($chunk);
            },
        ]);
        $ok = curl_exec($handle);
        $status = curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        curl_close($handle);
        if ($ok === false || $status !== 200) {
            // 不回显网关响应、请求正文或底层错误，避免泄露配置与签名。
            throw new \RuntimeException('付呗请求失败或结果未知，请核对原订单');
        }
        return $response;
    }
}
