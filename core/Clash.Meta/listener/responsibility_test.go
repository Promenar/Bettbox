package listener

import (
	C "github.com/metacubex/mihomo/constant"
	"testing"
)

func TestListenerResponsibilityQueryRetainsFailedClose(t *testing.T) {
	previous := inboundListeners
	t.Cleanup(func() { inboundListeners = previous })
	f := &checkedFixtureInbound{fail: true}
	inboundListeners = map[string]C.InboundListener{"公开责任": f}
	if !HasListenerResponsibility() || f.closeCalls.Load() != 0 {
		t.Fatal("责任查询不能执行清理")
	}
	if StopListenerChecked() == nil || !HasListenerResponsibility() {
		t.Fatal("关闭失败责任被查询清空")
	}
	f.fail = false
	if StopListenerChecked() != nil || HasListenerResponsibility() {
		t.Fatal("确认关闭后登记责任没有释放")
	}
}
