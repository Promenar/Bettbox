package androidstartup

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
)

type rejectedInputResource struct{ closes int }

func (r *rejectedInputResource) Close() error { r.closes++; return nil }

func TestRejectedInputPreservesRunningResource(t *testing.T) {
	var s State
	old := &rejectedInputResource{}
	oldReleases := 0
	if !s.Start(9, true, func() { oldReleases++ }, func(*OnceLease) (Resource, error) { return old, nil }) {
		t.Fatal("公开旧资源启动失败")
	}
	runtime := s.Runtime()
	releases, closes := 0, 0
	r := s.RejectInputWithCleanup(func() { releases++ }, func() error { closes++; return nil })
	if !r.InputCleanupConfirmed || r.Blocked || r.RetainsInputLease || r.Code != "" || releases != 1 || closes != 1 {
		t.Fatalf("拒绝输入收尾报告错误: %+v", r)
	}
	if old.closes != 0 || oldReleases != 0 || s.Runtime() != runtime {
		t.Fatal("拒绝新输入误停旧资源")
	}
	if !s.Stop() || old.closes != 1 || oldReleases != 1 {
		t.Fatal("旧资源不能正常停止")
	}
}

func TestRejectedInputUnknownPreservesResponsibility(t *testing.T) {
	for _, mode := range []string{"closeError", "closePanic", "releasePanic", "both"} {
		t.Run(mode, func(t *testing.T) {
			var s State
			old := &rejectedInputResource{}
			if !s.Start(9, true, nil, func(*OnceLease) (Resource, error) { return old, nil }) {
				t.Fatal("公开旧资源启动失败")
			}
			runtime := s.Runtime()
			closes, releases := 0, 0
			r := s.RejectInputWithCleanup(func() {
				releases++
				if mode == "releasePanic" || mode == "both" {
					panic("公开释放失败")
				}
			}, func() error {
				closes++
				if mode == "closePanic" {
					panic("公开关闭失败")
				}
				if mode == "closeError" || mode == "both" {
					return errors.New("公开关闭错误")
				}
				return nil
			})
			if r.InputCleanupConfirmed || !r.Blocked || closes != 1 || releases != 1 {
				t.Fatalf("未知收尾未保留: %+v", r)
			}
			if r.RetainsInputLease != (mode == "releasePanic" || mode == "both") {
				t.Fatal("lease责任错误")
			}
			if old.closes != 0 || s.Runtime() != runtime || s.Stop() {
				t.Fatal("未知收尾误停/清洗旧资源")
			}
			expected := startCodeInputCleanupFailed
			if mode == "closePanic" {
				expected = startCodeInputCleanupPanic
			}
			if mode == "releasePanic" {
				expected = startCodeReleasePanic
			}
			if r.Code != expected {
				t.Fatalf("首因错误: %s", r.Code)
			}
			later := s.RejectInputWithCleanup(func() { releases++ }, func() error { closes++; return nil })
			if !later.InputCleanupConfirmed || !later.Blocked || later.Code != expected || closes != 2 || releases != 2 {
				t.Fatalf("后续输入未清理或清洗未知: %+v", later)
			}
		})
	}
}

func TestRejectedInputConcurrentCleanupsPreserveOldResource(t *testing.T) {
	var s State
	old := &rejectedInputResource{}
	if !s.Start(9, true, nil, func(*OnceLease) (Resource, error) { return old, nil }) {
		t.Fatal("旧资源启动失败")
	}
	runtime := s.Runtime()
	var calls atomic.Int32
	var bad atomic.Bool
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := s.RejectInputWithCleanup(func() { calls.Add(1) }, func() error { calls.Add(1); return nil })
			if !r.InputCleanupConfirmed || r.Blocked {
				bad.Store(true)
			}
		}()
	}
	wg.Wait()
	if bad.Load() || calls.Load() != 32 || old.closes != 0 || s.Runtime() != runtime {
		t.Fatal("并发拒绝输入改变旧资源或遗漏清理")
	}
	if !s.Stop() || old.closes != 1 {
		t.Fatal("旧资源收尾失败")
	}
}

func TestRejectedInputEmptyStateDoesNotStartRuntime(t *testing.T) {
	var s State
	r := s.RejectInputWithCleanup(nil, nil)
	if !r.InputCleanupConfirmed || r.Blocked || r.RetainsInputLease || r.Code != "" || !s.Runtime().IsZero() || !s.Stop() {
		t.Fatalf("空输入产生虚假运行或责任: %+v", r)
	}
}
