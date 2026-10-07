<?php

// 纯 PHP 契约测试：无框架启动、真实配置读取、网络请求或数据库写入。
require_once __DIR__ . '/../../plugins/Fubei/Signature.php';
require_once __DIR__ . '/../../plugins/Fubei/Amount.php';
require_once __DIR__ . '/../../plugins/Fubei/Client.php';
require_once __DIR__ . '/../../plugins/Fubei/Notification.php';
require_once __DIR__ . '/../../plugins/Fubei/JsonAmount.php';
require_once __DIR__ . '/../../plugins/Fubei/RawNotification.php';

use Plugin\Fubei\Amount;
use Plugin\Fubei\Client;
use Plugin\Fubei\Notification;
use Plugin\Fubei\Signature;
use Plugin\Fubei\JsonAmount;
use Plugin\Fubei\RawNotification;

$count = 0;
function check(bool $condition, string $name): void
{
    global $count;
    if (!$condition) throw new RuntimeException('验证失败：' . $name);
    $count++;
}
function rejects(callable $operation, string $name): void
{
    $rejected = false;
    try { $operation(); } catch (Throwable $e) { $rejected = true; }
    check($rejected, $name);
}

$fixture = json_decode(file_get_contents(__DIR__ . '/fixture.json'), true, 32, JSON_THROW_ON_ERROR);
$params = $fixture['params'];
$secret = $fixture['secret'];
check(Signature::verify($params, $secret), '固定公开样例签名');
check(Signature::verify(array_reverse($params, true), $secret), 'ASCII 参数排序');
$changed = $params;
$changed['data'] = str_replace('12.34', '12.35', $changed['data']);
check(!Signature::verify($changed, $secret), '金额篡改拒绝');
$changed = $params;
$changed['data'] .= ' ';
check(!Signature::verify($changed, $secret), '原始 data 字节变化拒绝');
check(!Signature::verify($params, 'wrong-public-test-secret'), '错误密钥拒绝');
$changed = $params;
$changed['sign'] = strtolower($changed['sign']);
check(!Signature::verify($changed, $secret), '签名必须为大写32位');
$changed = $params;
$changed['extra'] = 'x';
check(!Signature::verify($changed, $secret), '额外参数也参与签名');

foreach ([1 => '0.01', 100 => '1.00', 1234 => '12.34', 1000000000 => '10000000.00'] as $cents => $yuan) {
    check(Amount::toYuan($cents) === $yuan && Amount::fromYuan($yuan) === $cents, '精确金额转换 ' . $yuan);
}
rejects(fn() => Amount::fromYuan(12.34), '浮点金额直接调用拒绝');
check(JsonAmount::yuanToken('{"total_amount":12.34}') === '12.34', '原始 JSON 数字金额');
check(JsonAmount::yuanToken('{"nested":{"total_amount":99},"text":"total_amount:9", "total_amount":"12.34"}') === '12.34', '嵌套金额与字符串不影响顶层');
foreach ([
    '{"total_amount":12.3400000000000001}',
    '{"total_amount":1.234e1}',
    '{"total_amount":12.34,"total_amount":12.34}',
    '{"total_amount":12.34,"\\u0074otal_amount":12.34}',
    '{"total_amount":"\\u0031\\u0032.34"}',
    '{"total_amount":"12.34\\n"}',
    '{"total_amount":"12.34\\\""}',
    '{"total_amount":true}',
    '{"total_amount":null}',
    '{"total_amount":[12.34]}',
    '{"other":12.34}',
] as $badJson) {
    rejects(fn() => JsonAmount::yuanToken($badJson), '原始金额 token 拒绝');
}
$rawBody = http_build_query($params, '', '&', PHP_QUERY_RFC1738);
check(RawNotification::parse($rawBody, 'application/x-www-form-urlencoded; charset=utf-8', 'POST') === $params, '原表单保留 JSON 与中文');
$rawSpaced = array_replace($params, ['result_message' => ' 成功 ', 'data' => ' ' . $params['data'] . ' ']);
$rawSpaced['sign'] = Signature::sign($rawSpaced, $secret);
check(Signature::verify(RawNotification::parse(http_build_query($rawSpaced), 'application/x-www-form-urlencoded', 'POST'), $secret), '不受 TrimStrings 影响');
check(RawNotification::parse($rawBody . '&optional=', 'application/x-www-form-urlencoded', 'POST')['optional'] === '', '空字符串不转 null');
foreach ([$rawBody . '&data=x', $rawBody . '&%64ata=x', $rawBody . '&data[]=x', $rawBody . '&bad=%Q1', str_repeat('x', 1048577)] as $badBody) {
    rejects(fn() => RawNotification::parse($badBody, 'application/x-www-form-urlencoded', 'POST'), '原表单异常拒绝');
}
rejects(fn() => RawNotification::parse($rawBody, 'application/json', 'POST'), '错误内容类型拒绝');
rejects(fn() => RawNotification::parse($rawBody, 'application/x-www-form-urlencoded', 'GET'), '错误方法拒绝');
foreach ([0, -1, '01', 1.5, '1000000001', null] as $bad) {
    rejects(fn() => Amount::toYuan($bad), '无效分金额拒绝');
}
foreach (['0', '-1', '1.001', '1e2', ' 1.00', '01.00', '10000000.01', NAN, INF] as $bad) {
    rejects(fn() => Amount::fromYuan($bad), '无效元金额拒绝');
}

$config = [
    'identity_mode' => 'merchant', 'app_id' => 'PUBLIC_FIXTURE', 'merchant_id' => '123456',
    'store_id' => '789012', 'id' => 5, 'gateway' => 'https://gateway.example.test/pay',
    'gateway_hosts' => 'gateway.example.test', 'payment_hosts' => 'cashier.example.test',
    'notify_hosts' => 'notify.example.test', 'expired_time' => 600,
];
$order = ['trade_no' => 'ORDER202610070001', 'payment_id' => 5, 'total_amount' => 1200, 'handling_amount' => 34, 'status' => 0];
$data = Notification::decode($params, $secret);
$verified = Notification::validate($data, $order, $config);
check($verified['callback_no'] === 'FBTEST202610070001' && $verified['custom_result'] === 'success', '有效通知与手续费');
foreach (['uid' => 9, 'store_id' => 9, 'total_amount' => '12.00', 'merchant_order_sn' => 'OTHER', 'pay_type' => 'bankcardpay', 'order_status' => 'FAILED'] as $key => $bad) {
    $invalid = array_replace($data, [$key => $bad]);
    rejects(fn() => Notification::validate($invalid, $order, $config), '通知字段拒绝 ' . $key);
}
foreach (['uid', 'store_id', 'total_amount', 'merchant_order_sn', 'order_sn', 'order_status'] as $key) {
    $invalid = $data;
    unset($invalid[$key]);
    rejects(fn() => Notification::validate($invalid, $order, $config), '缺失字段拒绝 ' . $key);
}
rejects(fn() => Notification::validate($data, array_replace($order, ['payment_id' => 6]), $config), '错误支付归属');
rejects(fn() => Notification::validate($data, array_replace($order, ['status' => 2]), $config), '取消订单迟到通知拒绝');
rejects(fn() => Notification::validate($data, array_replace($order, ['status' => 4]), $config), '折抵订单拒绝');
foreach ([1, 3] as $state) {
    check(Notification::validate($data, array_replace($order, ['status' => $state, 'callback_no' => $data['order_sn']]), $config) === $verified, '相同流水顺序重复');
    rejects(fn() => Notification::validate($data, array_replace($order, ['status' => $state, 'callback_no' => 'OTHER']), $config), '重复通知流水冲突');
}
$invalid = $params;
$invalid['data'] = '{invalid-json';
$invalid['sign'] = Signature::sign($invalid, $secret);
rejects(fn() => Notification::decode($invalid, $secret), '已签名的非法 JSON');
$invalid = $params;
$invalid['result_code'] = '500';
$invalid['sign'] = Signature::sign($invalid, $secret);
rejects(fn() => Notification::decode($invalid, $secret), '已签名失败通知');
$invalid = $params;
$invalid['data'] = str_replace('12.34', '12.3400000000000001', $invalid['data']);
$invalid['sign'] = Signature::sign($invalid, $secret);
rejects(fn() => Notification::decode($invalid, $secret), '已签名长小数通知拒绝');

foreach (['http://gateway.example.test/pay', 'https://gateway.example.test.evil.test/pay', 'https://127.0.0.1/pay', 'https://user@gateway.example.test/pay', 'https://gateway.example.test:8443/pay', 'https://gateway.example.test/pay#x'] as $bad) {
    rejects(fn() => Client::httpsUrl($bad, $config['gateway_hosts']), 'HTTPS 白名单拒绝');
}
foreach (['identity_mode', 'app_id', 'merchant_id', 'store_id', 'gateway', 'gateway_hosts'] as $key) {
    $invalidConfig = $config;
    unset($invalidConfig[$key]);
    rejects(fn() => new Client($invalidConfig, $secret, fn() => ''), '缺失接入配置拒绝 ' . $key);
}
rejects(fn() => new Client($config + ['vendor_sn' => 'OTHER'], $secret, fn() => ''), '身份二选一');
rejects(fn() => new Client($config, '', fn() => ''), '无密钥拒绝');

$calls = 0;
$transport = function (string $url, string $body) use (&$calls, $secret): string {
    $calls++;
    check($url === 'https://gateway.example.test/pay', '显式网关');
    $request = json_decode($body, true, 32, JSON_THROW_ON_ERROR);
    check(Signature::verify($request, $secret), '实际请求结构签名');
    check($request['method'] === 'fbpay.fixed.qrcode.create', '聚合码 method');
    check(preg_match('/^[a-f0-9]{32}$/D', $request['nonce']) === 1, '随机 nonce 形状');
    $biz = json_decode($request['biz_content'], true, 32, JSON_THROW_ON_ERROR);
    check(!array_key_exists('merchant_id', $biz), '商户级不发送 merchant_id');
    check(str_contains($request['biz_content'], '"total_amount":12.34'), '金额为精确 JSON 数字');
    check($biz['store_id'] === 789012 && $biz['notify_url'] === 'https://notify.example.test/callback', '门店与回调映射');
    return json_encode(['result_code' => 200, 'data' => json_encode(['merchant_order_sn' => $biz['merchant_order_sn'], 'qrcode_url' => 'https://cashier.example.test/qr?id=fixture'])]);
};
$client = new Client($config, $secret, $transport);
$pay = ['trade_no' => $order['trade_no'], 'total_amount' => 1234, 'notify_url' => 'https://notify.example.test/callback'];
check($client->createQr($pay) === 'https://cashier.example.test/qr?id=fixture', '二维码响应');
check($calls === 1, '无自动重试');
rejects(fn() => $client->createQr(array_replace($pay, ['notify_url' => 'https://notify.example.test/callback?key=x'])), '查询参数回调拒绝');
rejects(fn() => $client->createQr(array_replace($pay, ['trade_no' => ' ORDER '])), '订单号空格拒绝');
rejects(fn() => (new Client(array_replace($config, ['expired_time' => 1801]), $secret, $transport))->createQr($pay), '过长有效期拒绝');
foreach ([
    ['result_code' => 500, 'data' => '{}'],
    ['result_code' => 200, 'data' => json_encode(['merchant_order_sn' => 'OTHER', 'qrcode_url' => 'https://cashier.example.test/qr'])],
    ['result_code' => 200, 'data' => json_encode(['merchant_order_sn' => $order['trade_no'], 'qrcode_url' => 'https://evil.example.test/qr'])],
    ['result_code' => 200, 'data' => ['merchant_order_sn' => $order['trade_no']]],
] as $response) {
    rejects(fn() => (new Client($config, $secret, fn() => json_encode($response)))->createQr($pay), '异常响应拒绝');
}
$vendorConfig = array_replace($config, ['identity_mode' => 'vendor', 'app_id' => '', 'vendor_sn' => 'VENDOR_FIXTURE']);
$vendor = new Client($vendorConfig, $secret, function ($url, $body): string {
    $request = json_decode($body, true, 32, JSON_THROW_ON_ERROR);
    check(isset($request['vendor_sn']) && !isset($request['app_id']), '服务商身份');
    $biz = json_decode($request['biz_content'], true, 32, JSON_THROW_ON_ERROR);
    check($biz['merchant_id'] === 123456, '服务商发送 merchant_id');
    return json_encode(['result_code' => 200, 'data' => json_encode(['merchant_order_sn' => $biz['merchant_order_sn'], 'qrcode_url' => 'https://cashier.example.test/qr'])]);
});
$vendor->createQr($pay);

require __DIR__ . '/adapter.php';

fwrite(STDOUT, '纯契约验证通过：' . $count . ' 项。未验证真实支付或数据库并发。' . PHP_EOL);
