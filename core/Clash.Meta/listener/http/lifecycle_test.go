package http

import (
	"context"
	"errors"
	H "github.com/metacubex/http"
	N "github.com/metacubex/mihomo/common/net"
	C "github.com/metacubex/mihomo/constant"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

type lifecycleRejectTunnel struct {
	left, right net.Conn
	fallback    atomic.Int32
	called      chan struct{}
}

func (t *lifecycleRejectTunnel) HandleTCPConn(c net.Conn, _ *C.Metadata) {
	t.fallback.Add(1)
	select {
	case t.called <- struct{}{}:
	default:
	}
	_ = c.Close()
}
func (*lifecycleRejectTunnel) HandleUDPPacket(C.UDPPacket, *C.Metadata) {
	panic("TCP回归不应路由UDP")
}
func (*lifecycleRejectTunnel) NatTable() C.NatTable                         { return nil }
func (*lifecycleRejectTunnel) StartOwnedTCPConn(net.Conn, *C.Metadata) bool { return false }
func (*lifecycleRejectTunnel) StartOwnedTask(func()) bool                   { return false }
func (t *lifecycleRejectTunnel) NewOwnedPipe() (net.Conn, net.Conn, error) {
	t.left, t.right = N.Pipe()
	return t.left, t.right, nil
}

func TestHTTPOwnedAdmissionRejectedDoesNotFallbackAndClosesPipe(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	accepted := make(chan net.Conn, 1)
	go func() { c, _ := raw.Accept(); accepted <- c }()
	peer, err := net.DialTimeout("tcp", raw.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	src := <-accepted
	defer src.Close()
	tunnel := &lifecycleRejectTunnel{called: make(chan struct{}, 1)}
	client := newClient(src, tunnel, nil)
	defer client.CloseIdleConnections()
	transport := client.Transport.(*H.Transport)
	c, err := transport.DialContext(context.Background(), "tcp", "public.invalid:80")
	if err == nil || c != nil {
		t.Fatal("owned路由拒绝被降级为成功Dial")
	}
	for _, end := range []net.Conn{tunnel.left, tunnel.right} {
		if end == nil {
			t.Fatal("内部pipe没有创建")
		}
		_ = end.SetReadDeadline(time.Now().Add(time.Second))
		if _, err := end.Read(make([]byte, 1)); !errors.Is(err, io.ErrClosedPipe) && !errors.Is(err, io.EOF) {
			t.Fatal("路由拒绝没有关闭pipe")
		}
	}
	var tasks atomic.Int32
	taskCalled := make(chan struct{}, 1)
	if startHTTPTask(tunnel, func() { tasks.Add(1); taskCalled <- struct{}{} }) {
		t.Fatal("owned读取任务拒绝被降级")
	}
	select {
	case <-tunnel.called:
		t.Fatal("拒绝后legacy路由被启动")
	case <-taskCalled:
		t.Fatal("拒绝后legacy读取被启动")
	case <-time.After(50 * time.Millisecond):
	}
	if tasks.Load() != 0 || tunnel.fallback.Load() != 0 {
		t.Fatal("拒绝后仍有legacy任务副作用")
	}
}
