//go:build !cgo

package main

import (
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type ownedFakeListener struct {
	mu     sync.Mutex
	active bool
	closes int
	fail   bool
}

func (l *ownedFakeListener) Endpoint() (string, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return "127.0.0.1:34567", l.active
}
func (l *ownedFakeListener) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closes++
	if l.fail {
		return errors.New("虚构关闭错误")
	}
	l.active = false
	return nil
}
func listenerFixture(factory func() (ownedListenerResource, error)) (*ownedSession, *ownedListenerOwner) {
	s := newOwnedSession(nil, handleAction)
	s.ready = true
	s.generation = 7
	o := newOwnedListenerOwner(&s.mu, factory, func() bool { return true }, handleActionDirect)
	s.control = o
	return s, o
}
func listenerCall(s *ownedSession, method Method, data interface{}) ActionResult {
	result := ActionResult{Id: "fixture", Method: method}
	result.ownedSend = func(value []byte) { _ = json.Unmarshal(value, &result) }
	s.mu.Lock()
	result.ownedControl = s.control.admitLocked(s.generation)
	s.mu.Unlock()
	handleAction(&Action{Id: "fixture", Method: method, Data: data}, result)
	return result
}
func emptyOwnedData() interface{}   { return map[string]interface{}{} }
func fixtureRevoke(s *ownedSession) { s.mu.Lock(); s.control.revokeLocked(); s.mu.Unlock() }
func waitOwned(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(time.Second):
		t.Fatal("夹具未到达屏障")
	}
}
func TestOwnedListenerLegacyAndInputDenied(t *testing.T) {
	for _, method := range []Method{ownedHttpStartMethod, ownedHttpStopMethod, ownedHttpGetMethod} {
		var code int
		handleAction(&Action{Id: "x", Method: method, Data: emptyOwnedData()}, ActionResult{ownedSend: func(b []byte) { var r ActionResult; _ = json.Unmarshal(b, &r); code = r.Code }})
		if code != -1 {
			t.Fatal("仅发送函数不能授予入口能力")
		}
	}
	var calls atomic.Int32
	s, _ := listenerFixture(func() (ownedListenerResource, error) { calls.Add(1); return &ownedFakeListener{active: true}, nil })
	for _, data := range []interface{}{nil, "{}", map[string]interface{}{"port": 1}, []interface{}{}} {
		if listenerCall(s, ownedHttpStartMethod, data).Code != -1 {
			t.Fatal("非固定空对象获准")
		}
	}
	if calls.Load() != 0 {
		t.Fatal("拒绝输入创建了入口")
	}
}
func TestOwnedListenerConcurrentStartAndEpoch(t *testing.T) {
	var calls atomic.Int32
	s, o := listenerFixture(func() (ownedListenerResource, error) { calls.Add(1); return &ownedFakeListener{active: true}, nil })
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); listenerCall(s, ownedHttpStartMethod, emptyOwnedData()) }()
	}
	wg.Wait()
	if calls.Load() != 1 {
		t.Fatal("并发start重复创建")
	}
	first := listenerCall(s, ownedHttpGetMethod, emptyOwnedData())
	if first.Code != 0 {
		t.Fatal("实际入口缺失")
	}
	if listenerCall(s, ownedHttpStopMethod, emptyOwnedData()).Code != 0 {
		t.Fatal("停止失败")
	}
	if listenerCall(s, ownedHttpGetMethod, emptyOwnedData()).Code != -1 {
		t.Fatal("停止后仍有active端口")
	}
	listenerCall(s, ownedHttpStartMethod, emptyOwnedData())
	s.mu.Lock()
	epoch := o.epoch
	s.mu.Unlock()
	if calls.Load() != 2 || epoch != 2 {
		t.Fatal("同session重建epoch未更新")
	}
	fixtureRevoke(s)
	if o.drain(time.Second) != nil {
		t.Fatal("收口失败")
	}
}
func TestOwnedListenerLateConstructorWaitsAndCloses(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	l := &ownedFakeListener{active: true}
	s, o := listenerFixture(func() (ownedListenerResource, error) { close(entered); <-release; return l, nil })
	go func() {
		defer close(done)
		if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != -1 {
			t.Error("撤销后发布迟到入口")
		}
	}()
	waitOwned(t, entered)
	fixtureRevoke(s)
	if o.drain(time.Millisecond) == nil {
		t.Fatal("构造未返回却声称排空")
	}
	close(release)
	waitOwned(t, done)
	if o.drain(time.Second) != nil {
		t.Fatal("实际任务完成后未收口")
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closes != 1 || l.active {
		t.Fatal("迟到资源未恰一次关闭")
	}
}
func TestOwnedListenerCloseFailureSticky(t *testing.T) {
	l := &ownedFakeListener{active: true, fail: true}
	var calls atomic.Int32
	s, o := listenerFixture(func() (ownedListenerResource, error) { calls.Add(1); return l, nil })
	listenerCall(s, ownedHttpStartMethod, emptyOwnedData())
	if listenerCall(s, ownedHttpStopMethod, emptyOwnedData()).Code != -1 {
		t.Fatal("Close失败报告成功")
	}
	l.mu.Lock()
	l.fail = false
	l.mu.Unlock()
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != -1 || listenerCall(s, ownedHttpStopMethod, emptyOwnedData()).Code != -1 {
		t.Fatal("粘性错误被抹除")
	}
	fixtureRevoke(s)
	if o.drain(time.Second) == nil {
		t.Fatal("失败资源被称为收口")
	}
	s.mu.Lock()
	retained := o.resource == l
	s.mu.Unlock()
	if calls.Load() != 1 || !retained || l.closes != 1 {
		t.Fatal("失败资源丢失或重复关闭")
	}
}
func TestOwnedListenerAcceptFailureGetter(t *testing.T) {
	l := &ownedFakeListener{active: true}
	s, o := listenerFixture(func() (ownedListenerResource, error) { return l, nil })
	listenerCall(s, ownedHttpStartMethod, emptyOwnedData())
	l.mu.Lock()
	l.active = false
	l.mu.Unlock()
	if listenerCall(s, ownedHttpGetMethod, emptyOwnedData()).Code != -1 {
		t.Fatal("accept退出仍返回active")
	}
	fixtureRevoke(s)
	if o.drain(time.Second) != nil {
		t.Fatal("异常accept收口失败")
	}
}
func TestOwnedListenerConfigCloseBeforeDispatch(t *testing.T) {
	l := &ownedFakeListener{active: true}
	s, o := listenerFixture(func() (ownedListenerResource, error) { return l, nil })
	o.dispatch = func(a *Action, r ActionResult) {
		l.mu.Lock()
		closed := !l.active
		l.mu.Unlock()
		if !closed {
			t.Fatal("配置越过未关闭入口")
		}
		r.success("")
	}
	listenerCall(s, ownedHttpStartMethod, emptyOwnedData())
	if listenerCall(s, setupConfigMethod, "虚构公开配置").Code != 0 {
		t.Fatal("串行配置回执失败")
	}
	if listenerCall(s, ownedHttpGetMethod, emptyOwnedData()).Code != -1 {
		t.Fatal("配置后复用旧端口")
	}
	fixtureRevoke(s)
	if o.drain(time.Second) != nil {
		t.Fatal("配置收口失败")
	}
}
func TestOwnedListenerConfigFailureDoesNotDispatch(t *testing.T) {
	l := &ownedFakeListener{active: true, fail: true}
	s, o := listenerFixture(func() (ownedListenerResource, error) { return l, nil })
	var dispatched atomic.Int32
	o.dispatch = func(a *Action, r ActionResult) { dispatched.Add(1); r.success("") }
	listenerCall(s, ownedHttpStartMethod, emptyOwnedData())
	if listenerCall(s, shutdownMethod, nil).Code != -1 || dispatched.Load() != 0 {
		t.Fatal("停止不确定却执行全局shutdown")
	}
	fixtureRevoke(s)
	if o.drain(time.Second) == nil {
		t.Fatal("失败收口通过")
	}
}
func TestOwnedListenerEOFAndBackpressure(t *testing.T) {
	var o *ownedListenerOwner
	l := &ownedFakeListener{active: true}
	c := fixtureConfigured(t, handleAction, time.Second, func(s *ownedSession, _ *fixtureStream) {
		o = newOwnedListenerOwner(&s.mu, func() (ownedListenerResource, error) { return l, nil }, func() bool { return true }, handleActionDirect)
		s.control = o
	})
	helloFixture(t, c)
	<-c.stream.writes // ACK完成事件不作为业务背压证据。
	sendFixture(t, c, `{"protocol":1,"generation":7,"action":{"id":"start","method":"ownedHttpStart","data":{}}}`)
	// 客户端不读业务响应，生产sendResult真正阻塞在io.Pipe.Write。
	waitOwned(t, c.stream.writes)
	_ = c.input.Close()
	finishFixture(t, c, false)
	if o.drain(time.Second) != nil {
		t.Fatal("EOF/输出背压阻止生命周期收口")
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closes != 1 || l.active {
		t.Fatal("EOF未关闭真实归属资源")
	}
}

func TestOwnedListenerRejectedConfigBlocksStart(t *testing.T) {
	var calls atomic.Int32
	s, o := listenerFixture(func() (ownedListenerResource, error) { calls.Add(1); return &ownedFakeListener{active: true}, nil })
	o.dispatch = func(a *Action, r ActionResult) { r.success("虚构配置拒绝") }
	listenerCall(s, setupConfigMethod, "虚构公开配置")
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != -1 || calls.Load() != 0 {
		t.Fatal("拒绝配置后仍可启动")
	}
	o.dispatch = func(a *Action, r ActionResult) { r.success("") }
	listenerCall(s, setupConfigMethod, "虚构公开配置")
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != 0 {
		t.Fatal("确认配置未恢复入口准入")
	}
	fixtureRevoke(s)
	if o.drain(time.Second) != nil {
		t.Fatal("收口失败")
	}
}
func TestOwnedListenerLateFailedCloseRetainsResource(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	l := &ownedFakeListener{active: true, fail: true}
	s, o := listenerFixture(func() (ownedListenerResource, error) { close(entered); <-release; return l, nil })
	go func() { defer close(done); listenerCall(s, ownedHttpStartMethod, emptyOwnedData()) }()
	waitOwned(t, entered)
	fixtureRevoke(s)
	close(release)
	waitOwned(t, done)
	if o.drain(time.Second) == nil {
		t.Fatal("迟到构造Close失败仍宣称排空")
	}
	s.mu.Lock()
	retained := o.resource == l
	s.mu.Unlock()
	l.mu.Lock()
	defer l.mu.Unlock()
	if !retained || l.closes != 1 {
		t.Fatal("丢弃失败引用或重复关闭")
	}
}

func TestOwnedListenerConfigAndStartShareExecutionMutex(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	configured := make(chan struct{})
	started := make(chan struct{})
	var calls atomic.Int32
	s, o := listenerFixture(func() (ownedListenerResource, error) { calls.Add(1); return &ownedFakeListener{active: true}, nil })
	o.dispatch = func(a *Action, r ActionResult) { close(entered); <-release; r.success("") }
	go func() { defer close(configured); listenerCall(s, setupConfigMethod, "虚构公开配置") }()
	waitOwned(t, entered)
	// 主测试线程先登记第二个生产cap，避免只因goroutine尚未调度而得到假零次数。
	s.mu.Lock()
	cap := o.admitLocked(7)
	s.mu.Unlock()
	if cap == nil {
		t.Fatal("第二个请求未准入")
	}
	go func() {
		defer close(started)
		handleAction(&Action{Id: "next", Method: ownedHttpStartMethod, Data: emptyOwnedData()}, ActionResult{ownedControl: cap, ownedSend: func([]byte) {}})
	}()
	s.mu.Lock()
	pending := o.pending
	s.mu.Unlock()
	if pending != 2 || calls.Load() != 0 {
		t.Fatal("配置未返回却进入新构造")
	}
	select {
	case <-started:
		t.Fatal("配置未排空却完成start")
	default:
	}
	close(release)
	waitOwned(t, configured)
	waitOwned(t, started)
	if calls.Load() != 1 {
		t.Fatal("确认配置后未构造")
	}
	fixtureRevoke(s)
	if o.drain(time.Second) != nil {
		t.Fatal("收口失败")
	}
}
func TestOwnedListenerAdmissionBoundAndRevoked(t *testing.T) {
	s, o := listenerFixture(func() (ownedListenerResource, error) { t.Fatal("撤销任务不得构造"); return nil, nil })
	caps := make([]ownedListenerCapability, 0, ownedListenerTasks)
	s.mu.Lock()
	for i := 0; i < ownedListenerTasks; i++ {
		caps = append(caps, o.admitLocked(7))
	}
	if o.admitLocked(7) != nil {
		s.mu.Unlock()
		t.Fatal("预算超限仍准入")
	}
	o.revokeLocked()
	if o.admitLocked(7) != nil {
		s.mu.Unlock()
		t.Fatal("撤销后仍准入")
	}
	s.mu.Unlock()
	for _, cap := range caps {
		handleAction(&Action{Id: "a", Method: ownedHttpStartMethod, Data: emptyOwnedData()}, ActionResult{ownedControl: cap, ownedSend: func([]byte) {}})
	}
	if o.drain(time.Second) != nil {
		t.Fatal("已登记拒绝任务未排空")
	}
}

// 公开fake只模拟真实hub的isInit/currentConfig存留关系；准入判断执行生产cap/helper。
func TestOwnedListenerShutdownThenInitCannotRestoreConfig(t *testing.T) {
	var calls atomic.Int32
	s, o := listenerFixture(func() (ownedListenerResource, error) { calls.Add(1); return &ownedFakeListener{active: true}, nil })
	initialized, hasConfig := false, false
	o.ready = func() bool { return initialized && hasConfig }
	o.dispatch = func(a *Action, r ActionResult) {
		switch a.Method {
		case initClashMethod:
			initialized = true
			r.success(true)
		case setupConfigMethod, updateConfigMethod:
			hasConfig = true
			r.success("")
		case shutdownMethod:
			initialized = false
			r.success(true) // currentConfig保持非nil。
		default:
			r.error("公开夹具不支持")
		}
	}
	t.Cleanup(func() {
		fixtureRevoke(s)
		if o.drain(time.Second) != nil {
			t.Error("夹具生命周期未收口")
		}
	})
	if listenerCall(s, initClashMethod, "公开初始化").Code != 0 || listenerCall(s, setupConfigMethod, "公开配置").Code != 0 {
		t.Fatal("夹具初始化失败")
	}
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != 0 {
		t.Fatal("有效配置不能启动")
	}
	if listenerCall(s, shutdownMethod, nil).Code != 0 || listenerCall(s, initClashMethod, "公开初始化").Code != 0 {
		t.Fatal("夹具shutdown/init失败")
	}
	if !initialized || !hasConfig {
		t.Fatal("未复现真实旧currentConfig存留条件")
	}
	beforeCalls := calls.Load()
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != -1 || calls.Load() != beforeCalls {
		t.Fatal("shutdown后init不能恢复配置准入")
	}
	if listenerCall(s, setupConfigMethod, "公开确认配置").Code != 0 || listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != 0 {
		t.Fatal("有效setup未恢复准入")
	}
	if calls.Load() != beforeCalls+1 {
		t.Fatal("有效setup的构造次数错误")
	}
}
func TestOwnedListenerRejectedConfigThenInitCannotRestoreConfig(t *testing.T) {
	var calls atomic.Int32
	s, o := listenerFixture(func() (ownedListenerResource, error) { calls.Add(1); return &ownedFakeListener{active: true}, nil })
	initialized, hasConfig, reject := false, false, false
	o.ready = func() bool { return initialized && hasConfig }
	o.dispatch = func(a *Action, r ActionResult) {
		switch a.Method {
		case initClashMethod:
			initialized = true
			r.success(true)
		case setupConfigMethod, updateConfigMethod:
			if reject {
				r.success("公开配置拒绝")
			} else {
				hasConfig = true
				r.success("")
			}
		default:
			r.error("公开夹具不支持")
		}
	}
	t.Cleanup(func() {
		fixtureRevoke(s)
		if o.drain(time.Second) != nil {
			t.Error("夹具生命周期未收口")
		}
	})
	listenerCall(s, initClashMethod, "公开初始化")
	listenerCall(s, setupConfigMethod, "公开配置")
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != 0 {
		t.Fatal("有效配置不能启动")
	}
	reject = true
	listenerCall(s, setupConfigMethod, "公开拒绝配置")
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != -1 {
		t.Fatal("配置拒绝未阻止入口")
	}
	if listenerCall(s, initClashMethod, "公开初始化").Code != 0 || !initialized || !hasConfig {
		t.Fatal("未复现旧配置仍满足ready条件")
	}
	beforeCalls := calls.Load()
	if listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != -1 || calls.Load() != beforeCalls {
		t.Fatal("配置拒绝后init不能恢复配置准入")
	}
	reject = false
	if listenerCall(s, updateConfigMethod, "公开确认更新").Code != 0 || listenerCall(s, ownedHttpStartMethod, emptyOwnedData()).Code != 0 {
		t.Fatal("有效update未恢复准入")
	}
	if calls.Load() != beforeCalls+1 {
		t.Fatal("有效update的构造次数错误")
	}
}
