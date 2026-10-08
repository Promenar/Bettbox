package main

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
)

// 实例标识不是凭据；限制在JSON安全整数范围，JNI与Dart均可精确比对。
const androidRuntimeEpochMax int64 = (1 << 53) - 1

// Go库加载时只发行一次，不因Activity、Flutter engine或配置重建而重置。
// 无法取得实例身份时终止初始化，禁止降级为常量、时间戳或旧实例身份。
var androidConfigEpoch = mustAndroidRuntimeEpoch(rand.Reader)

func readAndroidRuntimeEpoch(reader io.Reader) (int64, error) {
	for attempt := 0; attempt < 8; attempt++ {
		var bytes [8]byte
		if _, err := io.ReadFull(reader, bytes[:]); err != nil {
			return 0, errors.New("内核运行时身份生成失败")
		}
		epoch := int64(binary.BigEndian.Uint64(bytes[:]) & uint64(androidRuntimeEpochMax))
		// 0表示身份缺失；1保留为旧固定协议值，不能作为新实例身份。
		if epoch > 1 {
			return epoch, nil
		}
	}
	return 0, errors.New("内核运行时身份生成失败")
}

func mustAndroidRuntimeEpoch(reader io.Reader) int64 {
	epoch, err := readAndroidRuntimeEpoch(reader)
	if err != nil {
		panic("内核运行时身份生成失败")
	}
	return epoch
}
