package http

import (
	"context"
	N "github.com/metacubex/mihomo/common/net"
	C "github.com/metacubex/mihomo/constant"
	"net"
)

func ownedHTTPContext(t C.Tunnel) context.Context {
	if owned, ok := t.(interface{ OwnedContext() context.Context }); ok {
		return owned.OwnedContext()
	}
	return context.Background()
}
func newHTTPPipe(t C.Tunnel) (net.Conn, net.Conn, error) {
	if owned, ok := t.(interface {
		NewOwnedPipe() (net.Conn, net.Conn, error)
	}); ok {
		return owned.NewOwnedPipe()
	}
	left, right := N.Pipe()
	return left, right, nil
}
func startHTTPTask(t C.Tunnel, task func()) bool {
	if owned, ok := t.(interface{ StartOwnedTask(func()) bool }); ok {
		return owned.StartOwnedTask(task)
	}
	go task()
	return true
}
