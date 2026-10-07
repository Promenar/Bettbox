//go:build !cgo

package main

import (
	"encoding/json"
	"errors"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const ownedListenerTasks = 8
const ownedListenerDrainBudget = 2 * time.Second

var errOwnedListener = errors.New("专用入口生命周期未确认")

type ownedListenerResource interface {
	Endpoint() (string, bool)
	Close() error
}
type ownedListenerEndpoint struct {
	Generation    int64  `json:"generation"`
	ListenerEpoch uint64 `json:"listenerEpoch"`
	Host          string `json:"host"`
	Port          int    `json:"port"`
	State         string `json:"state"`
}

// admission与ownedSession.mu是同一个锁；operation只保护生命周期执行，不保护stdout。
type ownedListenerOwner struct {
	admission     *sync.Mutex
	operation     sync.Mutex
	tasks         sync.WaitGroup
	pending       int
	generation    int64
	epoch         uint64
	revoked       bool
	failed        bool
	configInvalid bool
	resource      ownedListenerResource
	factory       func() (ownedListenerResource, error)
	ready         func() bool
	dispatch      func(*Action, ActionResult)
	drained       chan struct{}
}
type ownedListenerTask struct {
	owner      *ownedListenerOwner
	generation int64
	used       atomic.Bool
	finished   sync.Once
}

func newOwnedListenerOwner(mu *sync.Mutex, factory func() (ownedListenerResource, error), ready func() bool, dispatch func(*Action, ActionResult)) *ownedListenerOwner {
	return &ownedListenerOwner{admission: mu, factory: factory, ready: ready, dispatch: dispatch, drained: make(chan struct{})}
}

// 调用者持session.mu；必须在调度goroutine前登记，撤销后不再Add。
func (o *ownedListenerOwner) admitLocked(generation int64) ownedListenerCapability {
	if o.revoked || o.failed || generation <= 0 || o.pending >= ownedListenerTasks {
		return nil
	}
	if o.generation == 0 {
		o.generation = generation
	}
	if o.generation != generation {
		return nil
	}
	o.pending++
	o.tasks.Add(1)
	return &ownedListenerTask{owner: o, generation: generation}
}
func (t *ownedListenerTask) finish() {
	t.finished.Do(func() { o := t.owner; o.admission.Lock(); o.pending--; o.admission.Unlock(); o.tasks.Done() })
}
func (o *ownedListenerOwner) active(t *ownedListenerTask) bool {
	o.admission.Lock()
	defer o.admission.Unlock()
	return !o.revoked && !o.failed && o.generation == t.generation
}
func (o *ownedListenerOwner) poison() { o.admission.Lock(); o.failed = true; o.admission.Unlock() }

// 失败引用保持至进程退出，不能用后续成功或重复Close清洗首次失败。
func (o *ownedListenerOwner) closeResource() error {
	o.admission.Lock()
	failed := o.failed
	r := o.resource
	o.admission.Unlock()
	if failed {
		return errOwnedListener
	}
	if r == nil {
		return nil
	}
	if r.Close() != nil {
		o.poison()
		return errOwnedListener
	}
	o.admission.Lock()
	o.resource = nil
	o.admission.Unlock()
	return nil
}
func (o *ownedListenerOwner) revokeLocked() {
	if o.revoked {
		return
	}
	o.revoked = true
	go func() {
		o.tasks.Wait()
		o.operation.Lock()
		_ = o.closeResource()
		o.operation.Unlock()
		close(o.drained)
	}()
}
func (o *ownedListenerOwner) drain(budget time.Duration) error {
	timer := time.NewTimer(budget)
	defer timer.Stop()
	select {
	case <-o.drained:
	case <-timer.C:
		return errOwnedListener
	}
	o.admission.Lock()
	defer o.admission.Unlock()
	if o.failed || o.resource != nil || o.pending != 0 {
		return errOwnedListener
	}
	return nil
}
func emptyOwnedObject(data interface{}) bool {
	values, ok := data.(map[string]interface{})
	return ok && values != nil && len(values) == 0
}
func ownedEndpoint(r ownedListenerResource, generation int64, epoch uint64) (ownedListenerEndpoint, bool) {
	addr, active := r.Endpoint()
	if !active {
		return ownedListenerEndpoint{}, false
	}
	host, raw, err := net.SplitHostPort(addr)
	port, parse := strconv.Atoi(raw)
	if err != nil || parse != nil || host != "127.0.0.1" || port <= 0 || port > 65535 {
		return ownedListenerEndpoint{}, false
	}
	return ownedListenerEndpoint{generation, epoch, host, port, "active"}, true
}
func (t *ownedListenerTask) handle(a *Action, result ActionResult) {
	if !t.used.CompareAndSwap(false, true) {
		result.error(errOwnedListener.Error())
		return
	}
	o := t.owner
	var payload []byte
	captured := result
	captured.ownedControl = nil
	captured.ownedSend = func(value []byte) { payload = append([]byte(nil), value...) }
	o.operation.Lock()
	func() {
		defer func() {
			if recover() != nil {
				o.poison()
				captured.error(errOwnedListener.Error())
			}
		}()
		if !o.active(t) {
			captured.error(errOwnedListener.Error())
			return
		}
		if ownedHttpMethod(a.Method) {
			if !emptyOwnedObject(a.Data) {
				captured.error("专用入口参数拒绝")
				return
			}
			o.handleHTTP(t, a.Method, captured)
			return
		}
		if a.Method == startListenerMethod || a.Method == stopListenerMethod {
			captured.error("专用模式要求独立入口方法")
			return
		}
		// 配置、初始化和shutdown先确认旧专用入口关闭，不复用其端口。
		if o.closeResource() != nil || !o.active(t) {
			captured.error(errOwnedListener.Error())
			return
		}
		o.admission.Lock()
		previousInvalid := o.configInvalid
		o.configInvalid = true
		o.admission.Unlock()
		o.dispatch(a, captured)
		var completed ActionResult
		valid := json.Unmarshal(payload, &completed) == nil && completed.Code == 0
		if a.Method == initClashMethod || a.Method == shutdownMethod {
			accepted, ok := completed.Data.(bool)
			valid = valid && ok && accepted
		} else {
			message, ok := completed.Data.(string)
			valid = valid && ok && message == ""
		}
		o.admission.Lock()
		// 初始化只确认初始化结果，不能确认shutdown或配置拒绝后的配置有效性。
		switch a.Method {
		case setupConfigMethod, updateConfigMethod:
			o.configInvalid = !valid
		case initClashMethod:
			o.configInvalid = previousInvalid || !valid
		default:
			o.configInvalid = true
		}
		o.admission.Unlock()
		// 已入场同步业务可以完成；撤销后回执不能重新授权入口。
		if !o.active(t) {
			captured.error(errOwnedListener.Error())
		}
	}()
	o.operation.Unlock()
	if len(payload) == 0 || !json.Valid(payload) {
		o.poison()
		payload = []byte(`{"code":-1,"data":"专用入口回执拒绝"}`)
	}
	// 此Done只证明生命周期任务完成，不证明随后pipe写或其它Go业务结束。
	t.finish()
	if result.ownedSend != nil {
		result.ownedSend(payload)
	}
}
func (o *ownedListenerOwner) handleHTTP(t *ownedListenerTask, method Method, result ActionResult) {
	o.admission.Lock()
	r := o.resource
	epoch := o.epoch
	o.admission.Unlock()
	switch method {
	case ownedHttpStopMethod:
		if o.closeResource() != nil {
			result.error(errOwnedListener.Error())
			return
		}
		result.success(map[string]interface{}{"generation": t.generation, "listenerEpoch": epoch, "state": "stopped"})
		return
	case ownedHttpGetMethod:
		if r == nil {
			result.error("专用入口不可用")
			return
		}
		endpoint, ok := ownedEndpoint(r, t.generation, epoch)
		if !ok {
			_ = o.closeResource()
			result.error("专用入口不可用")
			return
		}
		if !o.active(t) {
			result.error(errOwnedListener.Error())
			return
		}
		result.success(endpoint)
		return
	case ownedHttpStartMethod:
		if r != nil {
			if endpoint, ok := ownedEndpoint(r, t.generation, epoch); ok {
				result.success(endpoint)
				return
			}
			if o.closeResource() != nil {
				result.error(errOwnedListener.Error())
				return
			}
		}
		o.admission.Lock()
		invalid := o.configInvalid
		o.admission.Unlock()
		if !o.active(t) || invalid || !o.ready() || epoch == ^uint64(0) {
			result.error("专用入口未就绪")
			return
		}
		created, err := o.factory()
		// 构造器的部分资源也归owner，不能在错误或撤销后丢弃。
		if created != nil {
			o.admission.Lock()
			o.resource = created
			o.admission.Unlock()
		}
		if err != nil || created == nil || !o.active(t) {
			_ = o.closeResource()
			result.error(errOwnedListener.Error())
			return
		}
		endpoint, ok := ownedEndpoint(created, t.generation, epoch+1)
		if !ok {
			_ = o.closeResource()
			result.error(errOwnedListener.Error())
			return
		}
		// 撤销与发布同锁；迟到构造不得发布或递增epoch。
		o.admission.Lock()
		publish := !o.revoked && !o.failed && o.generation == t.generation
		if publish {
			o.epoch++
		}
		o.admission.Unlock()
		if !publish {
			_ = o.closeResource()
			result.error(errOwnedListener.Error())
			return
		}
		result.success(endpoint)
	}
}
