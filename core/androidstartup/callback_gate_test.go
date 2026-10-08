package androidstartup

import (
	"errors"
	"runtime"
	"sync/atomic"
	"testing"
	"time"
)

func waitInflight(t *testing.T, g *CallbackGate, want int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		g.mu.Lock()
		count := g.inflight
		g.mu.Unlock()
		if count == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("夹具未到达指定 pin 屏障")
		}
		runtime.Gosched()
	}
}

func TestCapturedOldHandlerRejectsLateCallback(t *testing.T) {
	old := NewCallbackGate(4)
	captured := old
	old.CloseAdmission()
	old.Wait()
	refReads := 0
	if pin, ok := captured.Enter(); ok {
		refReads++
		pin.Done()
	}
	if refReads != 0 {
		t.Fatal("已关闭旧实例仍读取 JNI 引用")
	}
	newGate := NewCallbackGate(4)
	pin, ok := newGate.Enter()
	if !ok {
		t.Fatal("新实例不应影响旧捕获引用")
	}
	pin.Done()
	newGate.CloseAdmission()
	newGate.Wait()
}

func TestFourActiveAndQueuedPinCancelBeforeRealLastDone(t *testing.T) {
	g := NewCallbackGate(4)
	pins := make([]*CallbackPin, 4)
	for i := range pins {
		var ok bool
		pins[i], ok = g.Enter()
		if !ok {
			t.Fatal("有效 pin 拒绝")
		}
	}
	queued := make(chan bool, 1)
	go func() {
		pin, ok := g.Enter()
		if ok {
			pin.Done()
		}
		queued <- ok
	}()
	waitInflight(t, g, 5)
	var releases atomic.Int32
	lease := NewOnceLease(func() { releases.Add(1) })
	listenerClosed := make(chan struct{})
	closeDone := make(chan error, 1)
	var shutdown Shutdown
	go func() { closeDone <- shutdown.Close(g, lease, func() error { close(listenerClosed); return nil }) }()
	select {
	case <-listenerClosed:
	case <-time.After(time.Second):
		t.Fatal("关闭错误等待全部 permit")
	}
	select {
	case ok := <-queued:
		if ok {
			t.Fatal("queued Acquire 未取消")
		}
	case <-time.After(time.Second):
		t.Fatal("queued pin 未退出")
	}
	for _, pin := range pins[:3] {
		pin.Done()
		pin.Done()
	}
	waitInflight(t, g, 1)
	if releases.Load() != 0 {
		t.Fatal("最后 JNI 返回前释放引用")
	}
	select {
	case <-closeDone:
		t.Fatal("最后真实 Done 前声称关闭完成")
	default:
	}
	pins[3].Done()
	select {
	case err := <-closeDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("pin 排空后未完成关闭")
	}
	if releases.Load() != 1 {
		t.Fatal("引用没有恰好释放一次")
	}
}

func TestShutdownPreservesFirstListenerError(t *testing.T) {
	g := NewCallbackGate(4)
	closes, releases := 0, 0
	lease := NewOnceLease(func() { releases++ })
	var shutdown Shutdown
	closeListener := func() error { closes++; return errors.New("虚构原始错误内容") }
	first := shutdown.Close(g, lease, closeListener)
	second := shutdown.Close(g, lease, closeListener)
	if first == nil || second == nil || first.Error() != "TUN listener 关闭失败" || first != second {
		t.Fatal("错误被吞掉、泄露或重复关闭伪转成功")
	}
	if closes != 1 || releases != 1 {
		t.Fatal("关闭/释放不是 once")
	}
}

type failedResource struct{ closes int }

func (r *failedResource) Close() error { r.closes++; return errors.New("虚构关闭失败") }

func TestStopErrorRetainsStateAndRejectsNewStart(t *testing.T) {
	var s State
	oldReleases, newReleases, opens := 0, 0, 0
	r := &failedResource{}
	if !s.Start(7, true, func() { oldReleases++ }, func(*OnceLease) (Resource, error) { return r, nil }) {
		t.Fatal("启动失败")
	}
	started := s.Runtime()
	if s.Stop() || s.resource != r || s.lease == nil || !s.Runtime().Equal(started) || oldReleases != 0 {
		t.Fatal("失败停机丢失所有权或清空 runtime")
	}
	if s.Start(8, true, func() { newReleases++ }, func(*OnceLease) (Resource, error) { opens++; return &fakeResource{}, nil }) {
		t.Fatal("失败停机后接受新启动")
	}
	if newReleases != 1 || oldReleases != 0 || opens != 0 || !s.Runtime().Equal(started) {
		t.Fatal("新引用未清理或旧状态被替换")
	}
}

func TestPartialStartCloseErrorKeepsLeaseWithoutRuntime(t *testing.T) {
	var s State
	releases := 0
	r := &failedResource{}
	if s.Start(7, true, func() { releases++ }, func(*OnceLease) (Resource, error) { return r, errors.New("虚构启动失败") }) {
		t.Fatal("部分资源错误报告成功")
	}
	if s.resource != r || s.lease == nil || releases != 0 || !s.Runtime().IsZero() {
		t.Fatal("部分失败资源丢失或提前释放")
	}
	if s.Stop() || releases != 0 {
		t.Fatal("重复失败停机伪转成功")
	}
}

type managedFailedResource struct {
	gate     *CallbackGate
	lease    *OnceLease
	shutdown Shutdown
	closes   int
}

func (r *managedFailedResource) Close() error {
	return r.shutdown.Close(r.gate, r.lease, func() error { r.closes++; return errors.New("虚构失败") })
}

func TestSafeGateReleaseDoesNotTurnFailedStateStopIntoSuccess(t *testing.T) {
	var s State
	releases := 0
	r := &managedFailedResource{gate: NewCallbackGate(4)}
	if !s.Start(7, true, func() { releases++ }, func(lease *OnceLease) (Resource, error) { r.lease = lease; return r, nil }) {
		t.Fatal("启动失败")
	}
	started := s.Runtime()
	if s.Stop() || s.Stop() {
		t.Fatal("首次关闭错误不能在重复停机时伪转成功")
	}
	if releases != 1 || r.closes != 1 || s.resource != r || s.lease == nil || !s.Runtime().Equal(started) {
		t.Fatal("安全释放 gate 引用不应丢弃失败状态所有权")
	}
}

func TestPreexistingCleanupFailurePreservesPartialStateWithoutRetry(t *testing.T) {
	var s State
	var releases, newReleases atomic.Int32
	r := &managedFailedResource{gate: NewCallbackGate(4), closes: 1}
	if !r.shutdown.SeedCleanupFailure(errors.New("虚构已发生的首次关闭失败")) {
		t.Fatal("首次清理错误未登记")
	}
	pin, ok := r.gate.Enter()
	if !ok {
		t.Fatal("夹具 pin 创建失败")
	}
	started := make(chan bool, 1)
	go func() {
		started <- s.Start(7, true, func() { releases.Add(1) }, func(lease *OnceLease) (Resource, error) {
			r.lease = lease
			return r, errors.New("虚构初始化失败")
		})
	}()
	deadline := time.Now().Add(time.Second)
	for {
		r.gate.mu.Lock()
		closed := r.gate.closed
		r.gate.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("部分失败清理未关闭入场")
		}
		runtime.Gosched()
	}
	if releases.Load() != 0 {
		t.Fatal("活动 JNI 未退出就释放部分资源引用")
	}
	select {
	case <-started:
		t.Fatal("活动 JNI 未退出就结束部分资源清理")
	default:
	}
	pin.Done()
	select {
	case ok := <-started:
		if ok {
			t.Fatal("失败初始化报告成功")
		}
	case <-time.After(time.Second):
		t.Fatal("pin 排空后未返回")
	}
	if r.closes != 1 || releases.Load() != 1 || s.resource != r || s.lease == nil || !s.Runtime().IsZero() {
		t.Fatal("首个清理错误丢失、重试 Close 或部分所有权释放")
	}
	if s.Stop() || r.closes != 1 {
		t.Fatal("重复停机覆盖首次真实关闭错误")
	}
	if s.Start(8, true, func() { newReleases.Add(1) }, func(*OnceLease) (Resource, error) { t.Fatal("清理失败后不得创建新资源"); return nil, nil }) {
		t.Fatal("部分清理失败后接受新启动")
	}
	if newReleases.Load() != 1 {
		t.Fatal("被拒绝新 callback 未释放一次")
	}
}

func callShutdownCloseRecover(
	shutdown *Shutdown,
	gate *CallbackGate,
	lease *OnceLease,
	closeListener func() error,
) (err error, recovered any) {
	defer func() { recovered = recover() }()
	err = shutdown.Close(gate, lease, closeListener)
	return
}

func TestShutdownListenerErrorAndReleasePanicRemainSticky(t *testing.T) {
	gate := NewCallbackGate(1)
	listenerCalls, releaseCalls := 0, 0
	lease := NewOnceLease(func() {
		releaseCalls++
		panic("公开release panic")
	})
	var shutdown Shutdown
	first, recovered := callShutdownCloseRecover(&shutdown, gate, lease, func() error {
		listenerCalls++
		return errors.New("公开listener关闭失败")
	})
	if first == nil || recovered != nil {
		t.Fatal("listener错误叠加release panic未收敛为稳定失败")
	}
	second := shutdown.Close(gate, lease, func() error {
		listenerCalls++
		return nil
	})
	if second == nil || listenerCalls != 1 || releaseCalls != 1 {
		t.Fatalf("panic越过sync.Once后丢失首次失败：second=%v listeners=%d releases=%d", second, listenerCalls, releaseCalls)
	}
}

func TestShutdownListenerPanicStillReleasesAndRemainsSticky(t *testing.T) {
	gate := NewCallbackGate(1)
	listenerCalls, releaseCalls := 0, 0
	lease := NewOnceLease(func() { releaseCalls++ })
	var shutdown Shutdown
	first, recovered := callShutdownCloseRecover(&shutdown, gate, lease, func() error {
		listenerCalls++
		panic("公开listener close panic")
	})
	if first == nil || recovered != nil {
		t.Fatal("listener close panic未收敛为稳定失败")
	}
	second := shutdown.Close(gate, lease, func() error {
		listenerCalls++
		return nil
	})
	if second == nil || listenerCalls != 1 || releaseCalls != 1 {
		t.Fatalf("listener panic未完成一次清理并保留失败：second=%v listeners=%d releases=%d", second, listenerCalls, releaseCalls)
	}
}

func TestShutdownReleasePanicRemainsSticky(t *testing.T) {
	gate := NewCallbackGate(1)
	listenerCalls, releaseCalls := 0, 0
	lease := NewOnceLease(func() {
		releaseCalls++
		panic("公开release panic")
	})
	var shutdown Shutdown
	first, recovered := callShutdownCloseRecover(&shutdown, gate, lease, func() error {
		listenerCalls++
		return nil
	})
	if first == nil || recovered != nil {
		t.Fatal("release panic未收敛为稳定失败")
	}
	second := shutdown.Close(gate, lease, func() error {
		listenerCalls++
		return nil
	})
	if second == nil || listenerCalls != 1 || releaseCalls != 1 {
		t.Fatalf("release panic未保留失败：second=%v listeners=%d releases=%d", second, listenerCalls, releaseCalls)
	}
}
