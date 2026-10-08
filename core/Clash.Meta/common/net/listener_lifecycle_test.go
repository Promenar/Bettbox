package net

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func handshakeFixture(t *testing.T, handle func(context.Context, net.Conn) (net.Conn, error), report func(any)) (net.Listener, net.Listener) {
	t.Helper()
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	wrapped := NewHandleContextListener(context.Background(), raw, handle, report)
	t.Cleanup(func() { _ = raw.Close() })
	return wrapped, raw
}

func handshakePeer(t *testing.T, listener net.Listener) net.Conn {
	t.Helper()
	peer, err := net.DialTimeout("tcp", listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = peer.Close() })
	return peer
}

func TestHandleContextCloseInterruptsActualPendingHandshake(t *testing.T) {
	entered := make(chan net.Conn, 1)
	finished := make(chan struct{})
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		entered <- c
		defer close(finished)
		_, err := c.Read(make([]byte, 1))
		return nil, err
	}, nil)
	accepted := make(chan struct{})
	go func() { _, _ = l.Accept(); close(accepted) }()
	_ = handshakePeer(t, l)
	var rawConn net.Conn
	select {
	case rawConn = <-entered:
	case <-time.After(time.Second):
		t.Fatal("实际握手未进入")
	}
	t.Cleanup(func() {
		_ = rawConn.Close()
		_ = l.Close()
		<-finished
		<-accepted
	})
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-finished:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("Close成功返回后实际握手仍阻塞在socket Read")
	}
}

func TestHandleContextCloseRetainsUnfinishedTaskUntilExplicitRetry(t *testing.T) {
	entered := make(chan net.Conn, 1)
	release := make(chan struct{})
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		entered <- c
		<-release
		return c, nil
	}, func(any) {})
	accepted := make(chan struct{})
	go func() { _, _ = l.Accept(); close(accepted) }()
	_ = handshakePeer(t, l)
	rawConn := <-entered
	t.Cleanup(func() {
		_ = rawConn.Close()
		_ = l.Close()
	})
	firstErr := l.Close()
	close(release)
	// 重试必须收束真实任务，不能把未返回的handler认定为已关闭。
	secondErr := l.Close()
	select {
	case <-accepted:
	case <-time.After(time.Second):
		t.Fatal("显式释放后Accept没有完成")
	}
	if firstErr == nil || secondErr != nil {
		t.Fatalf("任务未退出/重试结果错误：首次失败=%t，重试成功=%t", firstErr != nil, secondErr == nil)
	}
}

func TestHandleContextCloseCancelsPendingDeliveryWithoutClosedChannelPanic(t *testing.T) {
	entered := make(chan net.Conn, 2)
	var panics atomic.Int32
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		entered <- c
		return c, nil
	}, func(any) { panics.Add(1) })
	firstAccepted := make(chan net.Conn, 1)
	go func() { c, _ := l.Accept(); firstAccepted <- c }()
	_ = handshakePeer(t, l)
	firstRaw := <-entered
	first := <-firstAccepted
	if first == nil {
		t.Fatal("正常握手未交付")
	}
	_ = first.Close()
	_ = firstRaw.Close()
	secondPeer := handshakePeer(t, l)
	secondRaw := <-entered
	t.Cleanup(func() { _ = secondRaw.Close(); _ = l.Close() })
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	_ = secondPeer.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	_, err := secondPeer.Read(make([]byte, 1))
	var timeout net.Error
	if err == nil || (errors.As(err, &timeout) && timeout.Timeout()) {
		t.Fatal("待交付握手连接在Close成功后仍开放")
	}
	if panics.Load() != 0 {
		t.Fatal("正常取消向已关闭结果通道发送")
	}
}

// 包装对象有独立Close责任；故意保留失败或阻塞以验证重试账本。
type handshakeTestConn struct {
	net.Conn
	calls   atomic.Int32
	closeFn func(int32) error
}

func (c *handshakeTestConn) Close() error { return c.closeFn(c.calls.Add(1)) }

type handshakeTestListener struct {
	net.Listener
	calls   atomic.Int32
	closeFn func(int32) error
}

func (l *handshakeTestListener) Close() error { return l.closeFn(l.calls.Add(1)) }

func TestHandleContextCloseLeavesHandedSocketUsable(t *testing.T) {
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) { return c, nil }, nil)
	accepted := make(chan net.Conn, 1)
	go func() { c, _ := l.Accept(); accepted <- c }()
	peer := handshakePeer(t, l)
	conn := <-accepted
	if conn == nil {
		t.Fatal("正常连接没有交接")
	}
	defer conn.Close()
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetDeadline(time.Now().Add(time.Second))
	_ = peer.SetDeadline(time.Now().Add(time.Second))
	if _, err := peer.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 1)
	if _, err := conn.Read(b); err != nil || b[0] != 'x' {
		t.Fatal("Close错误关闭已交付连接")
	}
}

func TestHandleContextLateWrapperFailureRequiresExplicitRetry(t *testing.T) {
	entered := make(chan net.Conn, 1)
	release := make(chan struct{})
	returned := make(chan *handshakeTestConn, 1)
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		entered <- c
		<-release
		w := &handshakeTestConn{Conn: c}
		w.closeFn = func(n int32) error {
			if n == 1 {
				return errors.Join(net.ErrClosed, errors.New("公开测试未知失败"))
			}
			return c.Close()
		}
		returned <- w
		return w, nil
	}, nil)
	go func() { _, _ = l.Accept() }()
	_ = handshakePeer(t, l)
	<-entered
	if err := l.Close(); err == nil {
		t.Fatal("未退出任务误报成功")
	}
	close(release)
	wrapper := <-returned
	// 等待迟到结果的自动收尾，失败不能在后台自行重试。
	owner := l.(*handleContextListener)
	select {
	case <-owner.done:
	case <-time.After(time.Second):
		t.Fatal("迟到任务未退出")
	}
	owner.mu.Lock()
	var attempt *handshakeCloseAttempt
	for r := range owner.pending {
		if r.conn == wrapper {
			r.result.mu.Lock()
			attempt = r.result.attempt
			r.result.mu.Unlock()
		}
	}
	owner.mu.Unlock()
	if attempt == nil {
		t.Fatal("迟到包装关闭责任未保留")
	}
	select {
	case <-attempt.done:
	case <-time.After(time.Second):
		t.Fatal("包装Close未完成")
	}
	if err := l.Close(); err != nil {
		t.Fatal("显式重试未确认迟到包装对象")
	}
	if wrapper.calls.Load() != 2 {
		t.Fatalf("实际Close次数=%d", wrapper.calls.Load())
	}
}

func TestHandleContextConnAndErrorCloseBothResources(t *testing.T) {
	wrapped := make(chan *handshakeTestConn, 1)
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		w := &handshakeTestConn{Conn: c, closeFn: func(int32) error { return nil }}
		wrapped <- w
		return w, errors.New("公开握手失败")
	}, nil)
	go func() { _, _ = l.Accept() }()
	peer := handshakePeer(t, l)
	wrapper := <-wrapped
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if wrapper.calls.Load() != 1 {
		t.Fatal("返回包装对象责任丢失")
	}
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	_, err := peer.Read(make([]byte, 1))
	var timeout net.Error
	if err == nil || (errors.As(err, &timeout) && timeout.Timeout()) {
		t.Fatal("原始socket没有关闭")
	}
}

func TestHandleContextCloseBlocksWithinBudgetAndNoConcurrentRetry(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	entered := make(chan struct{})
	release := make(chan struct{})
	fixture := &handshakeTestListener{Listener: raw}
	fixture.closeFn = func(int32) error { close(entered); <-release; return raw.Close() }
	l := NewHandleContextListener(context.Background(), fixture, func(_ context.Context, c net.Conn) (net.Conn, error) { return c, nil }, nil)
	go func() { _, _ = l.Accept() }()
	start := time.Now()
	if err := l.Close(); err == nil {
		t.Fatal("阻塞Close误报成功")
	}
	<-entered
	if time.Since(start) > 1500*time.Millisecond {
		t.Fatal("实际Close超出总预算")
	}
	if err := l.Close(); err == nil {
		t.Fatal("未退出Close误报成功")
	}
	if fixture.calls.Load() != 1 {
		t.Fatal("未完成Close被并发重试")
	}
	close(release)
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestHandleContextFailedListenerCloseRequiresNextRound(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	fixture := &handshakeTestListener{Listener: raw}
	fixture.closeFn = func(n int32) error {
		_ = raw.Close()
		if n == 1 {
			return errors.New("公开测试失败")
		}
		return nil
	}
	l := NewHandleContextListener(context.Background(), fixture, func(_ context.Context, c net.Conn) (net.Conn, error) { return c, nil }, nil)
	firstErr := l.Close()
	if firstErr == nil || fixture.calls.Load() != 1 {
		t.Fatalf("首次未知失败被清洗：失败=%t，次数=%d", firstErr != nil, fixture.calls.Load())
	}
	if err := l.Close(); err != nil || fixture.calls.Load() != 2 {
		t.Fatal("显式重试失败")
	}
}

func TestHandleContextPanicAndLoggerPanicReleaseSocket(t *testing.T) {
	var reports atomic.Int32
	l, _ := handshakeFixture(t, func(context.Context, net.Conn) (net.Conn, error) { panic("公开测试原始内容") }, func(v any) {
		reports.Add(1)
		if v != errHandshakePanic {
			t.Error("日志传入原始panic内容")
		}
		panic("公开测试logger失败")
	})
	go func() { _, _ = l.Accept() }()
	peer := handshakePeer(t, l)
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	_, err := peer.Read(make([]byte, 1))
	if err == nil {
		t.Fatal("panic未关闭socket")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if reports.Load() != 1 {
		t.Fatal("固定诊断次数错误")
	}
}

func TestHandleContextNaturalAcceptFailureCancelsPendingRead(t *testing.T) {
	entered := make(chan struct{})
	finished := make(chan struct{})
	l, raw := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		close(entered)
		defer close(finished)
		_, err := c.Read(make([]byte, 1))
		return nil, err
	}, nil)
	go func() { _, _ = l.Accept() }()
	_ = handshakePeer(t, l)
	<-entered
	_ = raw.Close()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("原始Accept失败后握手仍阻塞")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestHandleContextNilResultAndPrune(t *testing.T) {
	for _, nilResult := range []bool{false, true} {
		t.Run(map[bool]string{false: "nil", true: "typed-nil"}[nilResult], func(t *testing.T) {
			l, _ := handshakeFixture(t, func(context.Context, net.Conn) (net.Conn, error) {
				if nilResult {
					var c *net.TCPConn
					return c, nil
				}
				return nil, nil
			}, nil)
			go func() { _, _ = l.Accept() }()
			peer := handshakePeer(t, l)
			_ = peer.SetReadDeadline(time.Now().Add(time.Second))
			_, err := peer.Read(make([]byte, 1))
			if err == nil {
				t.Fatal("无效返回未关闭socket")
			}
			owner := l.(*handleContextListener)
			deadline := time.Now().Add(time.Second)
			for {
				owner.mu.Lock()
				n := len(owner.pending)
				owner.mu.Unlock()
				if n == 0 {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("已确认失败握手记录未释放")
				}
				time.Sleep(time.Millisecond)
			}
			if err := l.Close(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestHandleContextConcurrentAcceptClosePreservesHandoff(t *testing.T) {
	for i := 0; i < 30; i++ {
		l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) { return c, nil }, nil)
		accepted := make(chan net.Conn, 1)
		go func() { c, _ := l.Accept(); accepted <- c }()
		peer := handshakePeer(t, l)
		closed := make(chan error, 1)
		go func() { closed <- l.Close() }()
		c := <-accepted
		if err := <-closed; err != nil {
			t.Fatal(err)
		}
		if c != nil {
			_ = c.SetDeadline(time.Now().Add(time.Second))
			_ = peer.SetDeadline(time.Now().Add(time.Second))
			_, err := peer.Write([]byte("x"))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := c.Read(make([]byte, 1)); err != nil {
				t.Fatal("已提交交接被Close撤销")
			}
			_ = c.Close()
		}
	}
}

func TestHandleContextParentCancelRejectsPendingHandoff(t *testing.T) {
	for i := 0; i < 30; i++ {
		raw, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		entered := make(chan struct{}, 2)
		l := NewHandleContextListener(ctx, raw, func(_ context.Context, c net.Conn) (net.Conn, error) { entered <- struct{}{}; return c, nil }, nil)
		first := make(chan net.Conn, 1)
		go func() { c, _ := l.Accept(); first <- c }()
		peer := handshakePeer(t, l)
		<-entered
		conn := <-first
		if conn == nil {
			t.Fatal("正常启动未交接")
		}
		_ = conn.Close()
		_ = peer.Close()
		_ = handshakePeer(t, l)
		<-entered
		owner := l.(*handleContextListener)
		owner.mu.Lock()
		cancel()
		result := make(chan net.Conn, 1)
		go func() { c, _ := l.Accept(); result <- c }()
		owner.mu.Unlock()
		if c := <-result; c != nil {
			_ = c.Close()
			t.Fatal("父context取消后仍成功交接")
		}
		if err := l.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestHandleContextBlockingWrapperCloseRetainsSingleAttempt(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	wrapperResult := make(chan *handshakeTestConn, 1)
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		w := &handshakeTestConn{Conn: c, closeFn: func(int32) error { close(entered); <-release; return nil }}
		wrapperResult <- w
		return w, errors.New("公开握手失败")
	}, nil)
	go func() { _, _ = l.Accept() }()
	_ = handshakePeer(t, l)
	wrapper := <-wrapperResult
	<-entered
	start := time.Now()
	if err := l.Close(); err == nil {
		t.Fatal("包装Close阻塞误报成功")
	}
	if time.Since(start) > 1500*time.Millisecond {
		t.Fatal("包装Close超出总预算")
	}
	if err := l.Close(); err == nil {
		t.Fatal("未完成包装Close误报成功")
	}
	if wrapper.calls.Load() != 1 {
		t.Fatal("阻塞包装Close被并发重试")
	}
	close(release)
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestHandleContextCloseBeforeLazyAcceptIsIdempotent(t *testing.T) {
	var calls atomic.Int32
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) { calls.Add(1); return c, nil }, nil)
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if c, err := l.Accept(); c != nil || !errors.Is(err, net.ErrClosed) {
		t.Fatal("懒启动已关闭后错误返回")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 0 {
		t.Fatal("已关闭监听仍启动握手")
	}
}

func TestHandleContextConcurrentCloseConfirmsActualEnd(t *testing.T) {
	entered := make(chan struct{})
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		close(entered)
		_, err := c.Read(make([]byte, 1))
		return nil, err
	}, nil)
	go func() { _, _ = l.Accept() }()
	_ = handshakePeer(t, l)
	<-entered
	results := make(chan error, 6)
	for i := 0; i < 6; i++ {
		go func() { results <- l.Close() }()
	}
	for i := 0; i < 6; i++ {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
}

type handshakeValueConn struct {
	net.Conn
	marker []byte
	calls  *atomic.Int32
}

func (c handshakeValueConn) Close() error { c.calls.Add(1); return c.Conn.Close() }

func TestHandleContextNonComparableWrapperRetainsActualType(t *testing.T) {
	var calls atomic.Int32
	reports := atomic.Int32{}
	l, _ := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) {
		return handshakeValueConn{Conn: c, marker: []byte{1}, calls: &calls}, nil
	}, func(any) { reports.Add(1) })
	result := make(chan net.Conn, 1)
	go func() { c, _ := l.Accept(); result <- c }()
	_ = handshakePeer(t, l)
	c := <-result
	if _, ok := c.(handshakeValueConn); !ok {
		t.Fatal("返回连接动态类型被替换")
	}
	_ = c.Close()
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || reports.Load() != 0 {
		t.Fatal("不可比较包装对象交接或关闭错误")
	}
}

func TestHandleContextNaturalFailureCancelsPendingDelivery(t *testing.T) {
	entered := make(chan struct{}, 2)
	l, raw := handshakeFixture(t, func(_ context.Context, c net.Conn) (net.Conn, error) { entered <- struct{}{}; return c, nil }, nil)
	result := make(chan net.Conn, 1)
	go func() { c, _ := l.Accept(); result <- c }()
	firstPeer := handshakePeer(t, l)
	<-entered
	first := <-result
	if first == nil {
		t.Fatal("启动连接未交接")
	}
	_ = first.Close()
	_ = firstPeer.Close()
	peer := handshakePeer(t, l)
	<-entered
	_ = raw.Close()
	owner := l.(*handleContextListener)
	select {
	case <-owner.done:
	case <-time.After(time.Second):
		t.Fatal("原始Accept失败后待交付发送者未退出")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	_, err := peer.Read(make([]byte, 1))
	var timeout net.Error
	if err == nil || (errors.As(err, &timeout) && timeout.Timeout()) {
		t.Fatal("自然退出后待交付socket未关闭")
	}
}

type handshakeLateListener struct {
	net.Listener
	acceptFn func() (net.Conn, error)
}

func (l handshakeLateListener) Accept() (net.Conn, error) { return l.acceptFn() }

func TestHandleContextLateRawAcceptFailureNotRetriedInSameClose(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	entered := make(chan *handshakeTestConn, 1)
	release := make(chan struct{})
	fixture := &handshakeTestListener{Listener: raw}
	fixture.closeFn = func(n int32) error {
		if n == 1 {
			close(release)
		}
		return raw.Close()
	}
	late := handshakeLateListener{Listener: fixture, acceptFn: func() (net.Conn, error) {
		c, err := raw.Accept()
		if err != nil {
			return nil, err
		}
		w := &handshakeTestConn{Conn: c, closeFn: func(n int32) error {
			if n == 1 {
				return errors.New("公开迟到socket关闭失败")
			}
			return c.Close()
		}}
		entered <- w
		<-release
		return w, nil
	}}
	var handlers atomic.Int32
	l := NewHandleContextListener(context.Background(), late, func(_ context.Context, c net.Conn) (net.Conn, error) { handlers.Add(1); return c, nil }, nil)
	go func() { _, _ = l.Accept() }()
	_ = handshakePeer(t, l)
	conn := <-entered
	t.Cleanup(func() { _ = conn.Conn.Close(); _ = l.Close() })
	if err := l.Close(); err == nil || conn.calls.Load() != 1 {
		t.Fatalf("迟到raw失败被同轮清洗：失败=%t次数=%d", err != nil, conn.calls.Load())
	}
	if handlers.Load() != 0 {
		t.Fatal("撤销准入后启动握手")
	}
	if err := l.Close(); err != nil || conn.calls.Load() != 2 {
		t.Fatal("迟到raw显式重试失败")
	}
}

func TestHandleContextCloseSlotRejectsStaleRound(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	value := &handshakeTestListener{Listener: raw, closeFn: func(int32) error { return errors.New("公开测试未知关闭") }}
	slot := &handshakeCloseSlot{value: value}
	first := slot.request(2)
	<-first.done
	stale := slot.request(1)
	<-stale.done
	same := slot.request(2)
	<-same.done
	if stale != first || same != first || value.calls.Load() != 1 {
		t.Fatal("旧round回退并重试同轮关闭")
	}
	next := slot.request(3)
	<-next.done
	if next == first || value.calls.Load() != 2 {
		t.Fatal("新显式round没有执行关闭")
	}
}
