<?php

namespace Plugin\Fubei;

final class Signature
{
    public static function sign(array $parameters, string $secret): string
    {
        if ($secret === '') {
            throw new \InvalidArgumentException('付呗密钥未配置');
        }
        unset($parameters['sign']);
        ksort($parameters, SORT_STRING);
        $parts = [];
        foreach ($parameters as $key => $value) {
            if (!is_string($key) || !preg_match('/^[a-zA-Z0-9_]+$/D', $key) || (!is_string($value) && !is_int($value))) {
                throw new \InvalidArgumentException('付呗签名参数格式不合法');
            }
            // 保留原始参数值；不得对 data 或 biz_content 重新编码、解码或转义。
            $parts[] = $key . '=' . $value;
        }
        return strtoupper(md5(implode('&', $parts) . $secret));
    }

    public static function verify(array $parameters, string $secret): bool
    {
        $provided = $parameters['sign'] ?? null;
        if (!is_string($provided) || !preg_match('/^[A-F0-9]{32}$/D', $provided)) {
            return false;
        }
        try {
            return hash_equals(self::sign($parameters, $secret), $provided);
        } catch (\InvalidArgumentException $e) {
            return false;
        }
    }
}
