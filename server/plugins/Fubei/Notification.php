<?php

namespace Plugin\Fubei;

final class Notification
{
    public static function decode(array $params, string $secret): array
    {
        if (!Signature::verify($params, $secret) || !in_array($params['result_code'] ?? null, [200, '200'], true)
            || !is_string($params['data'] ?? null) || strlen($params['data']) > 1048576
            || !is_string($params['result_message'] ?? null)) {
            throw new \InvalidArgumentException('付呗通知未通过验签或成功状态校验');
        }
        $data = json_decode($params['data'], true, 32, JSON_THROW_ON_ERROR);
        if (!is_array($data) || ($data['order_status'] ?? null) !== 'SUCCESS') {
            throw new \InvalidArgumentException('付呗订单未支付成功');
        }
        $data['total_amount'] = JsonAmount::yuanToken($params['data']);
        foreach (['merchant_order_sn', 'order_sn'] as $key) {
            if (!is_string($data[$key] ?? null) || !preg_match('/^[a-zA-Z0-9_-]{1,32}$/D', $data[$key])) {
                throw new \InvalidArgumentException('付呗通知订单标识不合法');
            }
        }
        return $data;
    }

    public static function validate(array $data, array $order, array $config): array
    {
        Client::identity($config);
        if (($data['order_status'] ?? null) !== 'SUCCESS' || !isset($data['merchant_order_sn'], $data['order_sn'])) {
            throw new \InvalidArgumentException('付呗订单成功字段缺失');
        }
        foreach (['uid' => 'merchant_id', 'store_id' => 'store_id'] as $field => $key) {
            if (!isset($data[$field]) || (string) $data[$field] !== (string) $config[$key]) {
                throw new \InvalidArgumentException('付呗通知商户或门店不匹配');
            }
        }
        if (!in_array($data['pay_type'] ?? null, ['wxpay', 'alipay'], true)
            || ($order['trade_no'] ?? null) !== $data['merchant_order_sn']
            || !isset($config['id'], $order['payment_id'])
            || !preg_match('/^[1-9][0-9]*$/D', (string) $config['id'])
            || (string) $config['id'] !== (string) $order['payment_id']) {
            throw new \InvalidArgumentException('付呗通知订单或支付归属不匹配');
        }
        $expected = Amount::cents($order['total_amount'] ?? null)
            + Amount::cents($order['handling_amount'] ?? 0, true);
        if (Amount::fromYuan($data['total_amount'] ?? null) !== Amount::cents($expected)) {
            throw new \InvalidArgumentException('付呗通知金额不匹配');
        }
        $status = $order['status'] ?? null;
        if (!in_array($status, [0, 1, 3, '0', '1', '3'], true)) {
            throw new \InvalidArgumentException('订单状态不允许接收付款');
        }
        if ((int) $status !== 0 && ($order['callback_no'] ?? null) !== $data['order_sn']) {
            throw new \InvalidArgumentException('重复通知支付流水不匹配');
        }
        return [
            'trade_no' => $data['merchant_order_sn'],
            'callback_no' => $data['order_sn'],
            'custom_result' => 'success',
        ];
    }
}
