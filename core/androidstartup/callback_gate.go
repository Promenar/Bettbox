package androidstartup

import (
	"context"
	"errors"
	"sync"
)

// CallbackGate 在等待 permit 之前登记 pin，关闭后不会再进入 JNI 引用区。
type CallbackGate struct {
	mu       sync.Mutex
	closed   bool
	inflight int
	cond     *sync.Cond
	ctx      context.Context
	cancel   context.CancelFunc
	permits  chan struct{}
}

func NewCallbackGate(capacity int) *CallbackGate {
	if capacity <= 0 {
		panic("回调容量必须为正数")
	}
	ctx, cancel := context.WithCancel(context.Background())
	g := &CallbackGate{ctx: ctx, cancel: cancel, permits: make(chan struct{}, capacity)}
	g.cond = sync.NewCond(&g.mu)
	return g
}

type CallbackPin struct {
	gate *CallbackGate
	once sync.Once
}

func (g *CallbackGate) Enter() (*CallbackPin, bool) {
	g.mu.Lock()
	if g.closed {
		g.mu.Unlock()
		return nil, false
	}
	g.inflight++
	g.mu.Unlock()
	select {
	case g.permits <- struct{}{}:
		g.mu.Lock()
		closed := g.closed
		g.mu.Unlock()
		if closed {
			<-g.permits
			g.done()
			return nil, false
		}
		return &CallbackPin{gate: g}, true
	case <-g.ctx.Done():
		g.done()
		return nil, false
	}
}

func (g *CallbackGate) done() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.inflight--
	if g.inflight == 0 {
		g.cond.Broadcast()
	}
}

// Done 必须覆盖 JNI 完整调用，不得在取得引用后提前归还 pin。
func (p *CallbackPin) Done() {
	if p != nil {
		p.once.Do(func() { <-p.gate.permits; p.gate.done() })
	}
}

func (g *CallbackGate) CloseAdmission() {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.closed {
		g.closed = true
		g.cancel()
	}
}

func (g *CallbackGate) Wait() {
	g.mu.Lock()
	defer g.mu.Unlock()
	for g.inflight != 0 {
		g.cond.Wait()
	}
}

// Shutdown 保存首次实际关闭结果；错误不会在重复 Close 时变为成功。
// 它不取得全部 permit，等待只保护 JNI 引用安全，不证明底层栈停止。
type Shutdown struct {
	once              sync.Once
	err               error
	seedMu            sync.Mutex
	initialCloseError error
	closeStarted      bool
}

// SeedCleanupFailure 在 adapter 接收部分资源后、首次 Close 前登记既有错误。
// 返回 false 表示合同被违反，不允许晚登记覆盖真实关闭结果。
func (s *Shutdown) SeedCleanupFailure(err error) bool {
	if err == nil {
		return false
	}
	s.seedMu.Lock()
	defer s.seedMu.Unlock()
	if s.closeStarted {
		return false
	}
	if s.initialCloseError == nil {
		s.initialCloseError = errors.New("TUN listener 关闭失败")
	}
	return true
}

func (s *Shutdown) Close(g *CallbackGate, lease *OnceLease, closeListener func() error) error {
	s.once.Do(func() {
		s.seedMu.Lock()
		s.closeStarted = true
		err := s.initialCloseError
		s.seedMu.Unlock()
		g.CloseAdmission()
		// newListener 已尝试关闭且失败，绝不再调用 Close 抹掉首个错误。
		if err == nil {
			err = closeListener()
		}
		g.Wait()
		lease.Release()
		if err != nil {
			s.err = errors.New("TUN listener 关闭失败")
		}
	})
	return s.err
}
