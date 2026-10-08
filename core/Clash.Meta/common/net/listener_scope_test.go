package net

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func managedScopeFixture(t *testing.T, serve func(*ListenerScope, net.Conn)) *ManagedTCPServer {
	t.Helper()
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := NewManagedTCPServer(context.Background(), raw, serve, nil)
	t.Cleanup(func() { _ = raw.Close(); _ = s.Close() })
	return s
}
func managedScopePeer(t *testing.T, s *ManagedTCPServer) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", s.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestManagedTCPMainExitRetainsChildAndRejectsLateAdmission(t *testing.T) {
	scopes := make(chan *ListenerScope, 1)
	childEntered := make(chan struct{})
	release := make(chan struct{})
	ended := make(chan struct{})
	s := managedScopeFixture(t, func(scope *ListenerScope, c net.Conn) {
		if _, ok := c.(*net.TCPConn); !ok {
			t.Error("真实accepted动态类型改变")
		}
		if !scope.StartTask(func() { close(childEntered); <-release; close(ended) }) {
			t.Error("正常子任务拒绝")
		}
		scopes <- scope
	})
	_ = managedScopePeer(t, s)
	scope := <-scopes
	<-childEntered
	select {
	case <-scope.ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("主handler结束没有撤销scope")
	}
	if left, right, err := scope.NewPipe(); left != nil || right != nil || !errors.Is(err, net.ErrClosed) {
		t.Fatal("迟到Dial产生新pipe")
	}
	var late atomic.Int32
	if scope.StartTask(func() { late.Add(1) }) {
		t.Fatal("撤销后任务仍准入")
	}
	if err := s.Close(); err == nil {
		t.Fatal("主handler结束后丢失未退出子任务")
	}
	close(release)
	<-ended
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if late.Load() != 0 {
		t.Fatal("迟到任务实际启动")
	}
}

func TestManagedTCPActualPipeAndChildAreDrained(t *testing.T) {
	type result struct {
		scope       *ListenerScope
		left, right net.Conn
	}
	scopes := make(chan result, 1)
	ended := make(chan struct{})
	s := managedScopeFixture(t, func(scope *ListenerScope, _ net.Conn) {
		left, right, err := scope.NewPipe()
		if err != nil {
			t.Error(err)
			return
		}
		if !scope.StartTask(func() { _, _ = right.Read(make([]byte, 1)); close(ended) }) {
			t.Error("正常route拒绝")
		}
		scopes <- result{scope, left, right}
		<-scope.Context().Done()
	})
	_ = managedScopePeer(t, s)
	r := <-scopes
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ended:
	default:
		t.Fatal("成功Close前pipe任务没有退出")
	}
	if r.left.Close() != nil || r.right.Close() != nil {
		t.Fatal("正常内部pipe关闭不幂等")
	}
	s.owner.mu.Lock()
	pending := len(s.owner.pending)
	s.owner.mu.Unlock()
	if pending != 0 {
		t.Fatal("已确认会话记录未释放")
	}
}

func TestManagedTCPPipeCloseUnknownNeedsExplicitRetry(t *testing.T) {
	pipes := make(chan *managedPipeConn, 1)
	s := managedScopeFixture(t, func(scope *ListenerScope, _ net.Conn) {
		left, right, err := scope.NewPipe()
		if err != nil {
			t.Error(err)
			return
		}
		managed := left.(*managedPipeConn)
		value := &handshakeTestConn{Conn: managed.Conn, closeFn: func(n int32) error {
			if n == 1 {
				return errors.Join(net.ErrClosed, errors.New("公开pipe未知失败"))
			}
			return managed.Conn.Close()
		}}
		managed.slot.mu.Lock()
		managed.slot.value = value
		managed.slot.mu.Unlock()
		pipes <- managed
		if !scope.StartTask(func() { _, _ = right.Read(make([]byte, 1)) }) {
			t.Error("正常pipe路由拒绝")
		}
		<-scope.Context().Done()
	})
	_ = managedScopePeer(t, s)
	pipe := <-pipes
	if err := s.Close(); err == nil {
		t.Fatal("内部pipe未知Close被清洗")
	}
	value := pipe.slot.value.(*handshakeTestConn)
	if value.calls.Load() != 1 {
		t.Fatal("内部pipe同轮重试")
	}
	if err := s.Close(); err != nil {
		t.Fatal("显式pipe重试未收束")
	}
	if value.calls.Load() != 2 {
		t.Fatal("显式重试次数错误")
	}
}

func TestManagedTCPNaturalFailureCancelsScopeAndPipe(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	entered := make(chan *ListenerScope, 1)
	ended := make(chan struct{})
	s := NewManagedTCPServer(context.Background(), raw, func(scope *ListenerScope, _ net.Conn) {
		_, right, err := scope.NewPipe()
		if err != nil {
			t.Error(err)
			return
		}
		if !scope.StartTask(func() { _, _ = right.Read(make([]byte, 1)); close(ended) }) {
			t.Error("route拒绝")
		}
		entered <- scope
		<-scope.Context().Done()
	}, nil)
	t.Cleanup(func() { _ = raw.Close(); _ = s.Close() })
	_ = managedScopePeer(t, s)
	scope := <-entered
	_ = raw.Close()
	select {
	case <-scope.Context().Done():
	case <-time.After(time.Second):
		t.Fatal("自然监听故障未取消scope")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ended:
	default:
		t.Fatal("自然故障后pipe任务未退出")
	}
}

func TestManagedTCPClientEOFPrunesActualTasksAndPipes(t *testing.T) {
	entered := make(chan struct{})
	ended := make(chan struct{})
	s := managedScopeFixture(t, func(scope *ListenerScope, c net.Conn) {
		_, right, err := scope.NewPipe()
		if err != nil {
			t.Error(err)
			return
		}
		if !scope.StartTask(func() { _, _ = right.Read(make([]byte, 1)); close(ended) }) {
			t.Error("正常任务拒绝")
		}
		close(entered)
		_, _ = c.Read(make([]byte, 1))
	})
	peer := managedScopePeer(t, s)
	<-entered
	_ = peer.Close()
	select {
	case <-ended:
	case <-time.After(time.Second):
		t.Fatal("正常EOF没有停止内部任务")
	}
	deadline := time.Now().Add(time.Second)
	for {
		s.owner.mu.Lock()
		n := len(s.owner.pending)
		s.owner.mu.Unlock()
		if n == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("正常EOF未及时prune")
		}
		time.Sleep(time.Millisecond)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
}
