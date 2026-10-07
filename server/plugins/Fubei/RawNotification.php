<?php

namespace Plugin\Fubei;

final class RawNotification
{
    public static function parse(string $body, string $contentType, string $method): array
    {
        if ($method !== 'POST' || !preg_match('/^application\/x-www-form-urlencoded(?:\s*;\s*charset\s*=\s*utf-8)?$/iD', trim($contentType))
            || $body === '' || strlen($body) > 1048576) {
            throw new \InvalidArgumentException('付呗原始通知请求格式不合法');
        }
        $fields = explode('&', $body);
        if (count($fields) > 32) throw new \InvalidArgumentException('付呗通知字段过多');
        $params = [];
        foreach ($fields as $field) {
            if (!str_contains($field, '=')) throw new \InvalidArgumentException('付呗通知表单字段不合法');
            [$key, $value] = explode('=', $field, 2);
            foreach ([$key, $value] as $encoded) {
                if (preg_match('/%(?![a-fA-F0-9]{2})/', $encoded)) throw new \InvalidArgumentException('付呗通知百分号编码不合法');
            }
            $key = urldecode($key);
            $value = urldecode($value);
            if (!preg_match('/^[a-zA-Z0-9_]+$/D', $key) || array_key_exists($key, $params)
                || !preg_match('//u', $value)) {
                throw new \InvalidArgumentException('付呗通知重复字段或字符编码不合法');
            }
            // 不使用 parse_str 或 request->input，避免字段覆盖、TrimStrings 与空值转换。
            $params[$key] = $value;
        }
        foreach (['sign', 'data', 'result_code', 'result_message'] as $required) {
            if (!array_key_exists($required, $params)) throw new \InvalidArgumentException('付呗通知必需字段缺失');
        }
        return $params;
    }
}
