//go:build with_gvisor

package iosbridge

import (
	"errors"
	"sync"
	"sync/atomic"

	C "github.com/metacubex/mihomo/constant"
	// Mihomo DNS 包初始化 SystemResolver，注入 listener 的 ResetConnection 依赖该前提。
	_ "github.com/metacubex/mihomo/dns"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
)

// Runtime 串行管理真实 Mihomo 注入 listener，包读写只取得当前 Adapter 快照。
type Runtime struct {
	mu        sync.Mutex
	adapter   atomic.Pointer[Adapter]
	listener  *sing_tun.Listener
	lifecycle atomic.Int32
}

const (
	Stopped int32 = iota
	Starting
	Running
	Stopping
	Failed
)

func (r *Runtime) Start(options LC.Tun, target C.Tunnel, capacity int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.listener != nil {
		return errors.New("包流内核已经启动")
	}
	r.lifecycle.Store(Starting)
	a, err := New(options.MTU, capacity)
	if err != nil {
		r.lifecycle.Store(Failed)
		return err
	}
	listener, err := sing_tun.NewWithTun(options, target, a)
	if err != nil {
		_ = a.Close()
		r.lifecycle.Store(Failed)
		return err
	}
	if err = a.Activate(); err != nil {
		_ = listener.Close()
		r.lifecycle.Store(Failed)
		return err
	}
	r.listener = listener
	r.adapter.Store(a)
	r.lifecycle.Store(Running)
	return nil
}

// Stop 先停止协议栈，再由 listener 关闭 Adapter；重复停止安全。
func (r *Runtime) Stop() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.listener == nil {
		r.lifecycle.Store(Stopped)
		return nil
	}
	listener := r.listener
	r.lifecycle.Store(Stopping)
	r.adapter.Store(nil)
	r.listener = nil
	err := listener.Close()
	if err != nil {
		r.lifecycle.Store(Failed)
	} else {
		r.lifecycle.Store(Stopped)
	}
	return err
}

func (r *Runtime) Adapter() *Adapter {
	return r.adapter.Load()
}

func (r *Runtime) Running() bool { return r.lifecycle.Load() == Running }
func (r *Runtime) State() int32  { return r.lifecycle.Load() }
