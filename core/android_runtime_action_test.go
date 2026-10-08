//go:build !cgo

package main

import (
	"encoding/json"
	"testing"
)

// 走与FFI invokeAction共用的实际动作分发，验证关联状态读取且不采用配置。
func TestAndroidRuntimeStatusActionReturnsCurrentInstance(t *testing.T) {
	withProductionAndroidConfigFixture(t)
	var reply ActionResult
	calls := 0
	result := ActionResult{Id: "public-runtime-status", Method: Method("getAndroidOwnedConfigStatus"), ownedSend: func(payload []byte) {
		calls++
		if err := json.Unmarshal(payload, &reply); err != nil {
			t.Fatal(err)
		}
	}}
	handleAction(&Action{Id: result.Id, Method: result.Method}, result)
	wire, ok := reply.Data.(string)
	if calls != 1 || !ok || reply.Code != 0 || reply.Id != result.Id || reply.Method != result.Method {
		t.Fatal("实际FFI动作分发没有返回关联配置状态")
	}
	var status androidOwnedConfigResult
	if err := json.Unmarshal([]byte(wire), &status); err != nil {
		t.Fatal(err)
	}
	if status.Epoch != androidConfigEpoch || status.Configured || status.Blocked || status.StateGeneration != 0 || productionAndroidConfigCoordinator.hasDesiredState {
		t.Fatal("状态查询没有当前身份或提前采用配置")
	}
}
