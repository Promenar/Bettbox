<?php

namespace Plugin\Fubei;

final class JsonAmount
{
    public static function yuanToken(string $json): string
    {
        // 先验证完整 JSON 语法；金额只读取原始 token，不使用解码后的 float。
        $decoded = json_decode($json, true, 32, JSON_THROW_ON_ERROR);
        if (!is_array($decoded) || !str_starts_with(ltrim($json), '{')) {
            throw new \InvalidArgumentException('付呗业务参数必须为 JSON 对象');
        }
        $position = strpos($json, '{') + 1;
        $seen = [];
        $amount = null;
        $length = strlen($json);
        while ($position < $length) {
            self::whitespace($json, $position);
            if ($json[$position] === '}') break;
            $keyStart = $position;
            self::stringEnd($json, $position);
            $key = json_decode(substr($json, $keyStart, $position - $keyStart), true, 2, JSON_THROW_ON_ERROR);
            if (isset($seen[$key])) throw new \InvalidArgumentException('付呗业务参数重复字段');
            $seen[$key] = true;
            self::whitespace($json, $position);
            $position++; // 完整 JSON 已验证，此处为冒号。
            self::whitespace($json, $position);
            $start = $position;
            self::valueEnd($json, $position);
            $token = trim(substr($json, $start, $position - $start));
            if ($key === 'total_amount') {
                // 字符串金额只接受直接十进制字符；不接受转义、指数或超过两位的小数。
                if (str_starts_with($token, '"')) {
                    if (str_contains($token, '\\')) throw new \InvalidArgumentException('金额字符串不得使用转义');
                    $token = substr($token, 1, -1);
                }
                Amount::fromYuan($token);
                $amount = $token;
            }
            self::whitespace($json, $position);
            if ($json[$position] === '}') break;
            $position++;
        }
        if ($amount === null) throw new \InvalidArgumentException('付呗通知缺少原始金额');
        return $amount;
    }

    private static function whitespace(string $json, int &$position): void
    {
        while (isset($json[$position]) && str_contains(" \t\r\n", $json[$position])) $position++;
    }

    private static function stringEnd(string $json, int &$position): void
    {
        if (($json[$position] ?? '') !== '"') throw new \InvalidArgumentException('JSON 字段格式不合法');
        $position++;
        while (isset($json[$position])) {
            $character = $json[$position++];
            if ($character === '\\') { $position++; continue; }
            if ($character === '"') return;
        }
        throw new \InvalidArgumentException('JSON 字符串未结束');
    }

    private static function valueEnd(string $json, int &$position): void
    {
        $depth = 0;
        while (isset($json[$position])) {
            $character = $json[$position];
            if ($character === '"') { self::stringEnd($json, $position); continue; }
            if ($character === '{' || $character === '[') { $depth++; $position++; continue; }
            if ($character === '}' || $character === ']') {
                if ($depth === 0) return;
                $depth--; $position++; continue;
            }
            if ($character === ',' && $depth === 0) return;
            $position++;
        }
    }
}
