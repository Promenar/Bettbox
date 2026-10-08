package sing_tun

import (
	"errors"
	"testing"

	LC "github.com/metacubex/mihomo/listener/config"
	tun "github.com/metacubex/sing-tun"
)

// nativeFDFailingStack 使用真实 Listener.Close 路径，仅替换栈资源。
type nativeFDFailingStack struct {
	tun.Stack
	closeCalls int
	firstError error
}

func (s *nativeFDFailingStack) Close() error {
	s.closeCalls++
	if s.closeCalls == 1 {
		return s.firstError
	}
	return nil
}

func TestNativeFDCleanupRetainsPartialListenerAndFirstError(t *testing.T) {
	firstError := errors.New("栈资源关闭失败")
	stack := &nativeFDFailingStack{firstError: firstError}
	listener := &Listener{tunStack: stack}

	partial, cleanupErr := cleanupFailedListener(listener, true)

	if !errors.Is(cleanupErr, firstError) {
		t.Fatalf("首次实际关闭错误丢失：%v", cleanupErr)
	}
	if partial != listener {
		t.Fatal("清理失败后丢弃了部分 Listener 所有权")
	}
	if stack.closeCalls != 1 {
		t.Fatalf("实际关闭次数 = %d，期望 1", stack.closeCalls)
	}
	if !listener.closed {
		t.Fatal("未经过真实 Listener.Close")
	}
}

func TestNativeFDCleanupClearsListenerAfterSuccessfulClose(t *testing.T) {
	stack := &nativeFDFailingStack{}
	listener := &Listener{tunStack: stack}

	partial, cleanupErr := cleanupFailedListener(listener, true)

	if partial != nil || cleanupErr != nil || stack.closeCalls != 1 || !listener.closed {
		t.Fatalf("清理结果不符：partial=%p err=%v closeCalls=%d closed=%v", partial, cleanupErr, stack.closeCalls, listener.closed)
	}
}

func TestNativeFDCleanupWithoutPartialResource(t *testing.T) {
	partial, cleanupErr := cleanupFailedListener(nil, true)
	if partial != nil || cleanupErr != nil {
		t.Fatalf("无资源时产生了清理结果：partial=%p err=%v", partial, cleanupErr)
	}
}

func TestLegacyCleanupKeepsExistingDiscardSemantics(t *testing.T) {
	stack := &nativeFDFailingStack{firstError: errors.New("旧入口关闭失败")}
	listener := &Listener{tunStack: stack}

	partial, cleanupErr := cleanupFailedListener(listener, false)

	if partial != nil || cleanupErr != nil || stack.closeCalls != 1 {
		t.Fatalf("旧入口清理语义改变：partial=%p err=%v closeCalls=%d", partial, cleanupErr, stack.closeCalls)
	}
}

func TestNativeFDOwnershipRejectsNonPositiveFDWithoutAdoption(t *testing.T) {
	for _, fd := range []int{-1, 0} {
		t.Run(map[int]string{-1: "负数FD", 0: "零FD"}[fd], func(t *testing.T) {
			adoptCalls := 0
			listener, err, cleanupErr := NewWithNativeFDOwnership(
				LC.Tun{FileDescriptor: fd}, nil, func() { adoptCalls++ },
			)
			if listener != nil || err == nil || cleanupErr != nil || adoptCalls != 0 {
				t.Fatalf("非法 FD 拒绝结果不符：listener=%p err=%v cleanupErr=%v adoptCalls=%d", listener, err, cleanupErr, adoptCalls)
			}
		})
	}
}

func TestNativeFDOwnershipRejectsInvalidTunnelBeforeAdoption(t *testing.T) {
	adoptCalls := 0
	listener, err, cleanupErr := NewWithNativeFDOwnership(
		LC.Tun{FileDescriptor: 42}, nil, func() { adoptCalls++ },
	)
	if listener != nil || err == nil || cleanupErr != nil || adoptCalls != 0 {
		t.Fatalf("无效 tunnel 拒绝结果不符：listener=%p err=%v cleanupErr=%v adoptCalls=%d", listener, err, cleanupErr, adoptCalls)
	}
}

func TestNativeFDOwnershipRejectsMissingAdoptionCallbackBeforeTunnelValidation(t *testing.T) {
	listener, err, cleanupErr := NewWithNativeFDOwnership(
		LC.Tun{FileDescriptor: 42}, nil, nil,
	)
	if listener != nil || cleanupErr != nil {
		t.Fatalf("缺失采纳回调时触碰了资源所有权：listener=%p cleanupErr=%v", listener, cleanupErr)
	}
	if err == nil || err.Error() != "原生 TUN 需要采纳回调" {
		t.Fatalf("缺失采纳回调未在 tunnel 验证前拒绝：%v", err)
	}
}

// 此测试验证 observer 的同步一次通知，不覆盖实际 NativeTun 构造路径。
func TestNativeFDAdoptionObserverNotifiesSynchronouslyOnce(t *testing.T) {
	adoptCalls := 0
	ownership := &nativeFDOwnership{adopted: func() { adoptCalls++ }}
	ownership.adopt()
	if adoptCalls != 1 {
		t.Fatalf("采纳通知未同步完成：adoptCalls=%d", adoptCalls)
	}
	ownership.adopt()
	if adoptCalls != 1 {
		t.Fatalf("重复发送采纳通知：adoptCalls=%d", adoptCalls)
	}
}
