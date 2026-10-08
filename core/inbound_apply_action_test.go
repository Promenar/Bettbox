//go:build !cgo

package main

import (
	"encoding/json"
	"errors"
	"net"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
)

// 生产调用链夹具只创建 loopback socket，不涉及节点、公网或设备权限。
type applyActionInbound struct {
	socket net.Listener
	calls  int
}

func (*applyActionInbound) Name() string            { return "公开部分创建" }
func (*applyActionInbound) Address() string         { return "127.0.0.1:0" }
func (*applyActionInbound) RawAddress() string      { return "127.0.0.1:0" }
func (*applyActionInbound) Config() C.InboundConfig { return stopActionConfig{"公开部分创建"} }
func (f *applyActionInbound) Listen(C.Tunnel) error {
	f.calls++
	var err error
	f.socket, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	return errors.New("公开创建失败")
}
func (f *applyActionInbound) Close() error {
	if f.socket == nil {
		return nil
	}
	err := f.socket.Close()
	if errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

func withInboundApplyActionFixture(t *testing.T) *applyActionInbound {
	t.Helper()
	withProductionAndroidConfigFixture(t)
	previousOwned := ownedListenerMode.Swap(false)
	previousRunning := isRunning
	isRunning = false
	f := &applyActionInbound{}
	currentConfig = &config.Config{General: &config.General{}, Listeners: map[string]C.InboundListener{"公开部分": f}}
	t.Cleanup(func() {
		if err := listener.StopListenerChecked(); err != nil {
			t.Error("生产部分创建夹具未完成清理")
		}
		_ = f.Close()
		isRunning = previousRunning
		ownedListenerMode.Store(previousOwned)
	})
	return f
}

func TestInboundApplyStartRejectsPartialSocketAndStopReleasesPort(t *testing.T) {
	f := withInboundApplyActionFixture(t)
	if handleStartListener() || isRunning || f.calls != 1 || f.socket == nil || !listener.HasListenerResponsibility() {
		t.Fatal("启动报告成功或丢失实际部分创建责任")
	}
	address := f.socket.Addr().String()
	if !handleStopListener() {
		t.Fatal("显式停止未确认实际部分资源")
	}
	rebound, err := net.Listen("tcp", address)
	if err != nil {
		t.Fatal("生产停止没有释放实际端口")
	}
	_ = rebound.Close()
}

func TestInboundApplyUpdateHandlerReturnsFailureAfterEnteredMutation(t *testing.T) {
	f := withInboundApplyActionFixture(t)
	isRunning = true
	// general 变更已经发生，失败不等于配置回滚。
	if handleUpdateConfig([]byte(`{"mixed-port":12345}`)) == "" || currentConfig.General.MixedPort != 12345 || f.calls != 1 {
		t.Fatal("更新失败被吞掉或未进入真实应用路径")
	}
	if handleUpdateConfig([]byte(`{}`)) == "" || f.calls != 1 {
		t.Fatal("未知责任被自动更新清洗或重复构造")
	}
}

func TestInboundApplyProductionAndroidUpdateBecomesStickyUnknown(t *testing.T) {
	f := withInboundApplyActionFixture(t)
	isRunning = true
	// 配置身份是公开夹具；实际变更调用生产 driver 和真实监听器。
	productionAndroidConfigCoordinator.configured = true
	productionAndroidConfigCoordinator.lastApplied = 1
	productionAndroidConfigCoordinator.lastAttempted = 1
	var failed androidOwnedConfigResult
	if err := json.Unmarshal([]byte(commitAndroidOwnedConfigJSON(androidConfigEpoch, 1, androidConfigKindUpdate, `{}`)), &failed); err != nil {
		t.Fatal(err)
	}
	if failed.Outcome != androidConfigOutcomeUnknown || failed.Phase != androidConfigPhaseEntered || !failed.Blocked || failed.ConfigRevision != 1 || failed.AttemptedRevision != 2 || failed.ErrorCode != androidConfigErrorUpdateApplyFailed || failed.Options != nil || f.calls != 1 {
		t.Fatal("生产更新没有保留进入后失败身份")
	}
	var retry androidOwnedConfigResult
	if err := json.Unmarshal([]byte(commitAndroidOwnedConfigJSON(androidConfigEpoch, 1, androidConfigKindUpdate, `{}`)), &retry); err != nil {
		t.Fatal(err)
	}
	if retry.Outcome != androidConfigOutcomeRejected || retry.ErrorCode != androidConfigErrorBlocked || retry.AttemptedRevision != 2 || f.calls != 1 {
		t.Fatal("重复更新清洗了生产未知状态")
	}
}
