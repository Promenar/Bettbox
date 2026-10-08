package tcp

import (
	"context"
	N "github.com/metacubex/mihomo/common/net"
	C "github.com/metacubex/mihomo/constant"
	"net"
)

// ScopeTunnel委派真实路由，HTTP子任务在公共owner中登记，UDP能力原样转交。
type ScopeTunnel struct {
	scope    *N.ListenerScope
	delegate C.Tunnel
}

func NewScopeTunnel(scope *N.ListenerScope, tunnel C.Tunnel) ScopeTunnel {
	return ScopeTunnel{scope, tunnel}
}
func (t ScopeTunnel) HandleTCPConn(c net.Conn, m *C.Metadata)      { t.delegate.HandleTCPConn(c, m) }
func (t ScopeTunnel) HandleUDPPacket(p C.UDPPacket, m *C.Metadata) { t.delegate.HandleUDPPacket(p, m) }
func (t ScopeTunnel) NatTable() C.NatTable                         { return t.delegate.NatTable() }
func (t ScopeTunnel) OwnedContext() context.Context                { return t.scope.Context() }
func (t ScopeTunnel) NewOwnedPipe() (net.Conn, net.Conn, error)    { return t.scope.NewPipe() }
func (t ScopeTunnel) StartOwnedTask(task func()) bool              { return t.scope.StartTask(task) }
func (t ScopeTunnel) StartOwnedTCPConn(c net.Conn, m *C.Metadata) bool {
	return t.scope.StartTask(func() { defer c.Close(); t.delegate.HandleTCPConn(c, m) })
}
