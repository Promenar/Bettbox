package http

import (
	C "github.com/metacubex/mihomo/constant"
	"net"
	"testing"
	"time"
)

// 实际loopback构造与关闭，仅核验入口快照，不访问SC或真实节点。
func TestOwnedEndpointTracksRealClose(t *testing.T) {
	l, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(net.Conn, *C.Metadata) {}})
	if err != nil {
		t.Fatal("公开入口创建失败")
	}
	t.Cleanup(func() {
		if l.Close() != nil {
			t.Error("入口清理失败")
		}
	})
	address, active := l.Endpoint()
	host, port, e := net.SplitHostPort(address)
	if !active || e != nil || host != "127.0.0.1" || port == "0" || port == "" {
		t.Fatal("实际入口端点未确认")
	}
	if l.Close() != nil {
		t.Fatal("实际入口关闭未完成")
	}
	if a, ok := l.Endpoint(); ok || a != "" {
		t.Fatal("已关闭入口仍返回active")
	}
	c, e := net.DialTimeout("tcp4", address, time.Second)
	if c != nil {
		c.Close()
	}
	if e == nil {
		t.Fatal("已关闭端口仍可连接")
	}
}
func TestOwnedEndpointRejectsAcceptExit(t *testing.T) {
	l, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(net.Conn, *C.Metadata) {}})
	if err != nil {
		t.Fatal("公开入口创建失败")
	}
	t.Cleanup(func() {
		if l.Close() != nil {
			t.Error("入口清理失败")
		}
	})
	if l.listener.Close() != nil {
		t.Fatal("故障夹具关闭socket失败")
	}
	select {
	case <-l.acceptedDone:
	case <-time.After(time.Second):
		t.Fatal("accept故障未真实退出")
	}
	if a, ok := l.Endpoint(); ok || a != "" {
		t.Fatal("accept已退出却返回active")
	}
}
