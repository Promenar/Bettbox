//go:build !cgo

package main

import (
	"encoding/json"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
	"testing"
)

// 实际登记监听资源，确认无身份旧请求不能关闭资源或清除运行时状态。
func TestProductionAndroidOwnedRejectsLegacyListenerAndShutdown(t *testing.T) {
	withProductionAndroidConfigFixture(t)
	var staged androidOwnedConfigResult
	if err := json.Unmarshal([]byte(commitAndroidOwnedConfigJSON(androidConfigEpoch, 0, androidConfigKindState, `{}`)), &staged); err != nil {
		t.Fatal(err)
	}
	assertStagedStateResult(t, staged)
	previousRunning := isRunning
	isRunning = true
	resource := &stopActionInbound{name: "公开Android所有者监听", fail: true}
	listener.PatchInboundListeners(map[string]C.InboundListener{resource.name: resource}, nil, true)
	t.Cleanup(func() {
		resource.fail = false
		if err := listener.StopListenerChecked(); err != nil {
			t.Error("公开监听收尾失败")
		}
		isRunning = previousRunning
	})
	if handleStopListener() || !isRunning || resource.closeCalls != 0 {
		t.Fatal("无所有者身份的旧stopListener进入资源关闭")
	}
	if handleShutdown() || !isInit || !isRunning || resource.closeCalls != 0 {
		t.Fatal("无所有者身份的旧shutdown改变运行时或资源")
	}
	isRunning = false
	if handleStartListener() || isRunning || resource.closeCalls != 0 {
		t.Fatal("无所有者身份的旧startListener发布运行态")
	}
}
