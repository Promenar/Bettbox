<?php

namespace Plugin\Fubei;

final class Amount
{
    public const MAX_CENTS = 1000000000;

    public static function cents(mixed $value, bool $allowZero = false): int
    {
        if (is_int($value)) {
            $text = (string) $value;
        } elseif (is_string($value)) {
            $text = $value;
        } else {
            throw new \InvalidArgumentException('分金额必须为整数');
        }
        if (!preg_match('/^(0|[1-9][0-9]{0,9})$/D', $text)) {
            throw new \InvalidArgumentException('分金额格式不合法');
        }
        $cents = (int) $text;
        if ($cents > self::MAX_CENTS || $cents < ($allowZero ? 0 : 1)) {
            throw new \InvalidArgumentException('分金额超出支持范围');
        }
        return $cents;
    }

    public static function toYuan(mixed $value): string
    {
        $cents = self::cents($value);
        return intdiv($cents, 100) . '.' . str_pad((string) ($cents % 100), 2, '0', STR_PAD_LEFT);
    }

    public static function fromYuan(mixed $value): int
    {
        if (is_int($value)) {
            $value = (string) $value;
        }
        if (!is_string($value) || !preg_match('/^(0|[1-9][0-9]{0,7})(?:\.([0-9]{1,2}))?$/D', $value, $matches)) {
            throw new \InvalidArgumentException('元金额必须为至多两位小数的非负十进制数');
        }
        return self::cents((int) $matches[1] * 100 + (int) str_pad($matches[2] ?? '', 2, '0'));
    }
}
