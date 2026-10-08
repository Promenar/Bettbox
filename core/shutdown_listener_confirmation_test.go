//go:build !cgo

package main

import (
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
)

func TestShutdownPreservesUnconfirmedListenerAndInitialization(t *testing.T) {
	previousOwned := ownedListenerMode.Swap(false)
	previousInit, previousRunning := isInit, isRunning
	isInit, isRunning = true, true
	failed := &stopActionInbound{name: "公开shutdown失败监听", fail: true}
	listener.PatchInboundListeners(map[string]C.InboundListener{failed.name: failed}, nil, true)
	t.Cleanup(func() {
		failed.fail = false
		if err := listener.StopListenerChecked(); err != nil {
			t.Error("公开shutdown夹具收尾未确认")
		}
		isInit, isRunning = previousInit, previousRunning
		ownedListenerMode.Store(previousOwned)
	})
	if handleShutdown() {
		t.Error("监听关闭失败却确认shutdown成功")
	}
	if !isInit {
		t.Error("关闭未确认却清除初始化状态")
	}
	if isRunning {
		t.Error("shutdown请求未关闭新监听准入")
	}
	if failed.closeCalls != 1 {
		t.Error("同次shutdown重复关闭失败对象")
	}
	failed.fail = false
	if err := listener.StopListenerChecked(); err != nil || failed.closeCalls != 2 {
		t.Error("shutdown丢弃未确认监听的重试责任")
	}
}

func TestShutdownConfirmedListenerClearsInitialization(t *testing.T) {
	previousOwned := ownedListenerMode.Swap(false)
	previousInit, previousRunning := isInit, isRunning
	isInit, isRunning = true, true
	closed := &stopActionInbound{name: "公开shutdown成功监听"}
	listener.PatchInboundListeners(map[string]C.InboundListener{closed.name: closed}, nil, true)
	t.Cleanup(func() {
		if err := listener.StopListenerChecked(); err != nil {
			t.Error("公开shutdown成功夹具收尾未确认")
		}
		isInit, isRunning = previousInit, previousRunning
		ownedListenerMode.Store(previousOwned)
	})
	if !handleShutdown() || isInit || isRunning || closed.closeCalls != 1 {
		t.Error("确认关闭后shutdown状态或资源责任不符")
	}
}
