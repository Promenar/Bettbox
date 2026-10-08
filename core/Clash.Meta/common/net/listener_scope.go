package net

import (
	"context"
	"net"
)

// ManagedTCPServer直接使用公共监听责任账本；不提供握手结果交接API。
type ManagedTCPServer struct{ owner *handleContextListener }

func (s *ManagedTCPServer) Addr() net.Addr { return s.owner.Listener.Addr() }
func (s *ManagedTCPServer) Close() error   { return s.owner.Close() }
func NewManagedTCPServer(ctx context.Context, l net.Listener, serve func(*ListenerScope, net.Conn), report func(any)) *ManagedTCPServer {
	owner := NewHandleContextListener(ctx, l, nil, report).(*handleContextListener)
	owner.serve = serve
	owner.once.Do(owner.init)
	return &ManagedTCPServer{owner: owner}
}

// ListenerScope的资源与任务隶属真实accepted记录；主处理器退出并不提前释放子任务。
type ListenerScope struct {
	owner  *handleContextListener
	record *handshakeRecord
	ctx    context.Context
	cancel context.CancelFunc
	closed bool
}

func (s *ListenerScope) Context() context.Context { return s.ctx }
func (s *ListenerScope) admittedLocked() bool {
	return !s.closed && !s.owner.closed && s.ctx.Err() == nil
}
func (s *ListenerScope) stop() {
	s.owner.mu.Lock()
	if !s.closed {
		s.closed = true
		s.cancel()
	}
	s.owner.mu.Unlock()
	s.owner.cleanup(s.record, 0)
}

// 任务计数在启动前提交；撤销后的回调不能创建新的goroutine。
func (s *ListenerScope) StartTask(task func()) bool {
	s.owner.mu.Lock()
	if !s.admittedLocked() {
		s.owner.mu.Unlock()
		return false
	}
	s.record.tasks++
	s.owner.workers.Add(1)
	s.owner.mu.Unlock()
	go func() {
		defer func() {
			if recover() != nil {
				s.stop()
				func() {
					defer func() { _ = recover() }()
					if s.owner.panicLog != nil {
						s.owner.panicLog(errHandshakePanic)
					}
				}()
			}
			s.owner.mu.Lock()
			s.record.tasks--
			s.owner.mu.Unlock()
			s.owner.prune(s.record)
			s.owner.workers.Done()
		}()
		task()
	}()
	return true
}

// 两端在同锁准入后创建并登记，迟到Dial不会在成功关闭后创建pipe。
func (s *ListenerScope) NewPipe() (net.Conn, net.Conn, error) {
	s.owner.mu.Lock()
	defer s.owner.mu.Unlock()
	if !s.admittedLocked() {
		return nil, nil, net.ErrClosed
	}
	left, right := Pipe()
	wrap := func(c net.Conn) net.Conn {
		slot := &handshakeCloseSlot{value: c}
		slot.onComplete = func() {
			s.owner.mu.Lock()
			slot.mu.Lock()
			confirmed := slot.confirmed
			slot.mu.Unlock()
			if confirmed {
				for i, value := range s.record.extra {
					if value == slot {
						s.record.extra = append(s.record.extra[:i], s.record.extra[i+1:]...)
						break
					}
				}
			}
			s.owner.mu.Unlock()
			s.owner.prune(s.record)
		}
		s.record.extra = append(s.record.extra, slot)
		return &managedPipeConn{Conn: c, scope: s, slot: slot}
	}
	return wrap(left), wrap(right), nil
}

// 仅内部pipe包装Close；accepted的TCP/TLS/Reality类型保持原样。
type managedPipeConn struct {
	net.Conn
	scope *ListenerScope
	slot  *handshakeCloseSlot
}

func (c *managedPipeConn) Close() error {
	c.scope.owner.mu.Lock()
	round := c.scope.owner.round
	c.scope.owner.mu.Unlock()
	a := c.slot.request(round)
	ctx, cancel := context.WithTimeout(context.Background(), handshakeCloseBudget)
	defer cancel()
	select {
	case <-a.done:
		if a.ok {
			return nil
		}
	case <-ctx.Done():
	}
	return errHandshakeCloseUnconfirmed
}
func (c *managedPipeConn) CloseWrite() error       { return c.Close() }
func (c *managedPipeConn) Upstream() any           { return c.Conn }
func (c *managedPipeConn) ReaderReplaceable() bool { return true }
func (c *managedPipeConn) WriterReplaceable() bool { return true }
