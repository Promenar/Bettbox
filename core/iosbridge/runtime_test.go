//go:build with_gvisor

package iosbridge

import (
	"net/netip"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
)

func TestRuntimeInitializesDNSDependency(t *testing.T) {
	if resolver.SystemResolver == nil {
		t.Fatal("独立 Runtime 没有初始化真实系统 DNS resolver")
	}
	// 使用真实依赖，不能用替身或忽略 panic 掩盖启动前提。
	resolver.ResetConnection()
}

func TestRealMihomoInjectedListenerLifecycle(t *testing.T) {
	var runtime Runtime
	options := LC.Tun{MTU: 1480, Stack: C.TunGvisor, Inet4Address: []netip.Prefix{netip.MustParsePrefix("198.18.0.1/30")}, Inet6Address: []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")}}
	if err := runtime.Start(options, tunnel.Tunnel, 4); err != nil {
		t.Fatal(err)
	}
	adapter := runtime.Adapter()
	if adapter == nil || !runtime.Running() {
		t.Fatal("真实 listener 没有启动")
	}
	if err := runtime.Start(options, tunnel.Tunnel, 4); err == nil {
		t.Fatal("重复启动未被拒绝")
	}
	if err := runtime.Stop(); err != nil {
		t.Fatal(err)
	}
	if runtime.Running() {
		t.Fatal("停止后仍返回运行状态")
	}
	if err := adapter.PushInbound(ipPacket(4)); err != ErrClosed {
		t.Fatalf("停止后允许入包: %v", err)
	}
	if err := runtime.Start(options, tunnel.Tunnel, 4); err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	for n := 0; n < 8; n++ {
		workers.Add(1)
		go func() { defer workers.Done(); _ = runtime.Stop() }()
	}
	done := make(chan struct{})
	go func() { workers.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("并发停止阻塞")
	}
}

func TestInjectedListenerErrorDoesNotPublishRuntime(t *testing.T) {
	var runtime Runtime
	// 损坏 DNS 劫持目标令真实 listener 初始化失败；不能暴露半启动 Adapter。
	err := runtime.Start(LC.Tun{MTU: 1480, Stack: C.TunGvisor, DNSHijack: []string{"invalid"}}, tunnel.Tunnel, 2)
	if err == nil {
		_ = runtime.Stop()
		t.Fatal("未拒绝损坏 DNS 配置")
	}
	if runtime.Running() {
		t.Fatal("失败初始化泄露活动运行态")
	}
	_ = runtime.Stop()
}

func TestRuntimeObservationDoesNotWaitForLifecycleLock(t *testing.T) {
	var runtime Runtime
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	result := make(chan bool, 1)
	go func() { result <- !runtime.Running() && runtime.State() == Stopped && runtime.Adapter() == nil }()
	select {
	case ok := <-result:
		if !ok {
			t.Fatal("初始状态错误")
		}
	case <-time.After(time.Second):
		t.Fatal("状态查询被生命周期锁阻塞")
	}
}
