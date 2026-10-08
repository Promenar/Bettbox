package androidstartup

import (
	"sync"
	"sync/atomic"
	"testing"
)

func TestLeaseDispositionConfirmedRelease(t *testing.T) {
	calls := 0
	l := NewOnceLease(func() { calls++ })
	if l.Disposition() != LeaseHeld {
		t.Fatal("尚未释放不是held")
	}
	if releaseLease(l) || l.Disposition() != LeaseReleased || releaseLease(l) || calls != 1 {
		t.Fatal("确认释放没有单次released事实")
	}
	if (*OnceLease)(nil).Disposition() != LeaseReleased {
		t.Fatal("无义务nil lease误报")
	}
}
func TestLeaseDispositionUnknownCannotBeCleanedByOnceRetry(t *testing.T) {
	calls := 0
	l := NewOnceLease(func() { calls++; panic("公开释放失败") })
	if !releaseLease(l) || l.Disposition() != LeaseUnknown {
		t.Fatal("释放panic未记unknown")
	}
	if !releaseLease(l) || l.Disposition() != LeaseUnknown || calls != 1 {
		t.Fatal("Once重试清洗unknown或重释放")
	}
}
func TestLeaseDispositionConcurrentReleaseAndSnapshot(t *testing.T) {
	var calls atomic.Int32
	entered, finish := make(chan struct{}), make(chan struct{})
	l := NewOnceLease(func() { calls.Add(1); close(entered); <-finish })
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); l.Release() }()
	<-entered
	if l.Disposition() != LeaseHeld {
		t.Fatal("进行中释放伪造确认")
	}
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			l.Release()
			if l.Disposition() != LeaseReleased {
				t.Error("并发释放报告不一致")
			}
		}()
	}
	close(finish)
	wg.Wait()
	if l.Disposition() != LeaseReleased || calls.Load() != 1 {
		t.Fatal("单次释放合同失败")
	}
}
