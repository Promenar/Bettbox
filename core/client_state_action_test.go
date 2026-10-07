//go:build !cgo

package main

import (
	"core/state"
	"encoding/json"
	"testing"
)

func TestStateActionReportsFixedFailureAndDoesNotCommit(t *testing.T) {
	_ = state.ApplyJSON([]byte(`{"current-profile-name":"PUBLIC_ORIGINAL"}`))
	var value struct {
		Code int         `json:"code"`
		Data interface{} `json:"data"`
	}
	result := ActionResult{ownedSend: func(payload []byte) {
		if json.Unmarshal(payload, &value) != nil {
			t.Fatal("公开结果fixture解析失败")
		}
	}}
	handleAction(&Action{Method: setStateMethod, Data: `{"current-profile-name":"PUBLIC_CHANGED","only-statistics-proxy":"INVALID"}`}, result)
	if value.Code != -1 || value.Data != "客户端状态格式无效" || state.Snapshot().CurrentProfileName != "PUBLIC_ORIGINAL" {
		t.Fatal("状态失败回传或原子提交合同未满足")
	}
	handleAction(&Action{Method: setStateMethod, Data: `{"current-profile-name":"PUBLIC_ACCEPTED"}`}, result)
	if value.Code != 0 || value.Data != true || state.Snapshot().CurrentProfileName != "PUBLIC_ACCEPTED" {
		t.Fatal("有效状态动作合同未满足")
	}
}
