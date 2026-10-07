package androidstartup

import (
	"errors"
	"reflect"
	"testing"
)

func TestQuickStartStopsAtFailedPreflight(t *testing.T) {
	cases := []struct {
		name        string
		initOK      bool
		stateErr    error
		setupResult string
		want        string
		calls       []string
	}{
		{"初始化失败", false, nil, "禁止到达", "init error", []string{"init"}},
		{"状态失败", true, errors.New("PUBLIC_DIAGNOSTIC_MUST_NOT_ESCAPE"), "禁止到达", "客户端状态格式无效", []string{"init", "state"}},
		{"配置成功", true, nil, "", "", []string{"init", "state", "setup"}},
		{"配置失败保留既有结果", true, nil, "PUBLIC_SETUP_ERROR", "PUBLIC_SETUP_ERROR", []string{"init", "state", "setup"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var calls []string
			result := QuickStart(
				func() bool { calls = append(calls, "init"); return tc.initOK },
				func() error { calls = append(calls, "state"); return tc.stateErr },
				func() string { calls = append(calls, "setup"); return tc.setupResult },
			)
			if result != tc.want || !reflect.DeepEqual(calls, tc.calls) {
				t.Fatalf("预检顺序或结果不匹配: calls=%v result=%q", calls, result)
			}
		})
	}
}
