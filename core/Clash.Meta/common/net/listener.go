package net

import (
	"context"
	"errors"
	"io"
	"net"
	"reflect"
	"sync"
	"time"
)

const handshakeCloseBudget = time.Second

var errHandshakeCloseUnconfirmed = errors.New("握手监听关闭未确认")
var errHandshakePanic = errors.New("握手任务异常")

type handshakeCloseAttempt struct {
	done chan struct{}
	ok   bool
}

// 保留实际Close任务；超时不能丢失责任或并发启动同一对象的重试。
type handshakeCloseSlot struct {
	mu         sync.Mutex
	value      io.Closer
	attempt    *handshakeCloseAttempt
	confirmed  bool
	round      uint64
	onComplete func()
}

func (s *handshakeCloseSlot) request(round uint64) *handshakeCloseAttempt {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attempt != nil {
		select {
		case <-s.attempt.done:
			if s.confirmed || round == 0 || round <= s.round {
				return s.attempt
			}
		default:
			if round > s.round {
				s.round = round
			}
			return s.attempt
		}
	}
	a := &handshakeCloseAttempt{done: make(chan struct{})}
	s.attempt, s.round = a, round
	go func() {
		ok := false
		defer func() {
			// Close的panic与未知错误同样保留责任，不传播原始内容。
			_ = recover()
			s.mu.Lock()
			a.ok, s.confirmed = ok, ok
			close(a.done)
			s.mu.Unlock()
			if s.onComplete != nil {
				s.onComplete()
			}
		}()
		ok = handshakeClosedError(s.value.Close(), 0)
	}()
	return a
}

// 聚合错误必须全部已关闭；不能用errors.Is抹去其中未知的关闭失败。
func handshakeClosedError(err error, depth int) bool {
	if err == nil || err == net.ErrClosed {
		return true
	}
	if depth >= 32 {
		return false
	}
	if many, ok := err.(interface{ Unwrap() []error }); ok {
		children := many.Unwrap()
		if len(children) == 0 {
			return false
		}
		for _, child := range children {
			if child == nil || !handshakeClosedError(child, depth+1) {
				return false
			}
		}
		return true
	}
	if one, ok := err.(interface{ Unwrap() error }); ok {
		child := one.Unwrap()
		return child != nil && handshakeClosedError(child, depth+1)
	}
	return false
}

type handshakeRecord struct {
	raw       *handshakeCloseSlot
	result    *handshakeCloseSlot
	conn      net.Conn
	taskEnded bool
}

type handleContextListener struct {
	net.Listener
	ctx      context.Context
	cancel   context.CancelFunc
	conns    chan *handshakeRecord
	done     chan struct{}
	once     sync.Once
	mu       sync.Mutex
	closed   bool
	err      error
	pending  map[*handshakeRecord]struct{}
	workers  sync.WaitGroup
	gate     chan struct{}
	round    uint64
	listener *handshakeCloseSlot
	handle   func(context.Context, net.Conn) (net.Conn, error)
	panicLog func(any)
}

func (l *handleContextListener) init() {
	l.mu.Lock()
	if l.closed {
		close(l.conns)
		close(l.done)
		l.mu.Unlock()
		return
	}
	l.mu.Unlock()
	watcherDone := make(chan struct{})
	go func() {
		defer close(watcherDone)
		<-l.ctx.Done()
		l.stop(net.ErrClosed)
	}()
	go func() {
		defer func() {
			l.workers.Wait()
			<-watcherDone
			// 仅Accept循环发布终态；所有发送者退出后关闭结果通道。
			close(l.conns)
			close(l.done)
		}()
		for {
			c, err := l.Listener.Accept()
			if err != nil {
				l.stop(err)
				return
			}
			r := &handshakeRecord{raw: &handshakeCloseSlot{value: c}}
			r.raw.onComplete = func() { l.prune(r) }
			l.mu.Lock()
			l.pending[r] = struct{}{}
			if l.closed || l.ctx.Err() != nil {
				r.taskEnded = true
				l.mu.Unlock()
				l.cleanup(r, 0)
				return
			}
			l.workers.Add(1)
			l.mu.Unlock()
			go l.handshake(r, c)
		}
	}()
}

func handshakeConnNil(c net.Conn) bool {
	if c == nil {
		return true
	}
	v := reflect.ValueOf(c)
	switch v.Kind() {
	case reflect.Pointer, reflect.Map, reflect.Slice, reflect.Func, reflect.Chan, reflect.Interface:
		return v.IsNil()
	}
	return false
}

func sameHandshakeConn(a, b net.Conn) bool {
	t := reflect.TypeOf(a)
	return t == reflect.TypeOf(b) && reflect.ValueOf(a).Comparable() && reflect.ValueOf(b).Comparable() && a == b
}

func (l *handleContextListener) handshake(r *handshakeRecord, raw net.Conn) {
	defer func() {
		if recover() != nil {
			l.cleanup(r, 0)
			func() {
				defer func() { _ = recover() }()
				if l.panicLog != nil {
					l.panicLog(errHandshakePanic)
				}
			}()
		}
		l.mu.Lock()
		r.taskEnded = true
		l.mu.Unlock()
		l.prune(r)
		l.workers.Done()
	}()
	conn, err := l.handle(l.ctx, raw)
	l.mu.Lock()
	if !handshakeConnNil(conn) {
		r.conn = conn
		if sameHandshakeConn(raw, conn) {
			r.result = r.raw
		} else {
			r.result = &handshakeCloseSlot{value: conn, onComplete: func() { l.prune(r) }}
		}
	}
	closed := l.closed || l.ctx.Err() != nil
	l.mu.Unlock()
	if err != nil || handshakeConnNil(conn) || closed {
		l.cleanup(r, 0)
		return
	}
	select {
	case l.conns <- r:
		// 真正的交接在Accept持锁提交，通道发送不能取消关闭责任。
	case <-l.ctx.Done():
		l.cleanup(r, 0)
	}
}

func (l *handleContextListener) cleanup(r *handshakeRecord, round uint64) []*handshakeCloseAttempt {
	l.mu.Lock()
	if round == 0 && l.closed {
		round = l.round
	}
	slots := []*handshakeCloseSlot{r.raw}
	if r.result != nil && r.result != r.raw {
		slots = append(slots, r.result)
	}
	l.mu.Unlock()
	attempts := make([]*handshakeCloseAttempt, 0, len(slots))
	for _, slot := range slots {
		attempts = append(attempts, slot.request(round))
	}
	return attempts
}

// 失败握手的已确认资源及时移除，避免长运行服务累积历史连接记录。
func (l *handleContextListener) prune(r *handshakeRecord) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !r.taskEnded {
		return
	}
	slots := []*handshakeCloseSlot{r.raw}
	if r.result != nil && r.result != r.raw {
		slots = append(slots, r.result)
	}
	for _, slot := range slots {
		slot.mu.Lock()
		confirmed := slot.confirmed
		slot.mu.Unlock()
		if !confirmed {
			return
		}
	}
	delete(l.pending, r)
}

func (l *handleContextListener) stop(err error) {
	l.stopRound(err, 0)
}

func (l *handleContextListener) stopRound(err error, round uint64) {
	l.mu.Lock()
	if round == 0 {
		round = l.round
	}
	if !l.closed {
		l.closed, l.err = true, err
		l.cancel()
	}
	records := make([]*handshakeRecord, 0, len(l.pending))
	for r := range l.pending {
		records = append(records, r)
	}
	l.mu.Unlock()
	l.listener.request(round)
	for _, r := range records {
		l.cleanup(r, round)
	}
}

func (l *handleContextListener) Accept() (net.Conn, error) {
	l.once.Do(l.init)
	select {
	case r, ok := <-l.conns:
		l.mu.Lock()
		defer l.mu.Unlock()
		if ok && !l.closed && l.ctx.Err() == nil {
			delete(l.pending, r)
			return r.conn, nil
		}
		if l.err != nil {
			return nil, l.err
		}
		return nil, net.ErrClosed
	case <-l.ctx.Done():
		l.mu.Lock()
		defer l.mu.Unlock()
		if l.err != nil {
			return nil, l.err
		}
		return nil, net.ErrClosed
	}
}

func (l *handleContextListener) Close() error {
	budget, cancel := context.WithTimeout(context.Background(), handshakeCloseBudget)
	defer cancel()
	select {
	case l.gate <- struct{}{}:
		defer func() { <-l.gate }()
	case <-budget.Done():
		return errHandshakeCloseUnconfirmed
	}
	l.mu.Lock()
	l.round++
	round := l.round
	l.mu.Unlock()
	l.stopRound(net.ErrClosed, round)
	l.once.Do(l.init)
	wait := func(a *handshakeCloseAttempt) bool {
		select {
		case <-a.done:
			return a.ok
		case <-budget.Done():
			return false
		}
	}
	// 先发起全部Close，随后等待；单个阻塞对象不能阻止其它资源释放。
	collect := func() []*handshakeCloseAttempt {
		l.mu.Lock()
		records := make([]*handshakeRecord, 0, len(l.pending))
		for r := range l.pending {
			records = append(records, r)
		}
		l.mu.Unlock()
		attempts := []*handshakeCloseAttempt{l.listener.request(round)}
		for _, r := range records {
			attempts = append(attempts, l.cleanup(r, round)...)
		}
		return attempts
	}
	attempts := collect()
	ok := true
	for _, a := range attempts {
		if !wait(a) {
			ok = false
			select {
			case <-a.done:
			default:
				return errHandshakeCloseUnconfirmed
			}
		}
	}
	select {
	case <-l.done:
	case <-budget.Done():
		return errHandshakeCloseUnconfirmed
	}
	// 任务退出后重新收集迟到包装对象，不能只确认握手前的raw socket。
	for _, a := range collect() {
		if !wait(a) {
			return errHandshakeCloseUnconfirmed
		}
	}
	if !ok {
		return errHandshakeCloseUnconfirmed
	}
	l.mu.Lock()
	l.pending = make(map[*handshakeRecord]struct{})
	l.mu.Unlock()
	return nil
}

func NewHandleContextListener(ctx context.Context, l net.Listener, handle func(context.Context, net.Conn) (net.Conn, error), panicLog func(any)) net.Listener {
	ctx, cancel := context.WithCancel(ctx)
	return &handleContextListener{
		Listener: l,
		listener: &handshakeCloseSlot{value: l},
		ctx:      ctx,
		cancel:   cancel,
		conns:    make(chan *handshakeRecord),
		done:     make(chan struct{}),
		pending:  make(map[*handshakeRecord]struct{}),
		gate:     make(chan struct{}, 1),
		handle:   handle,
		panicLog: panicLog,
	}
}
