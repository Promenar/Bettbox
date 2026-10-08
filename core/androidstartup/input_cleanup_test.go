package androidstartup

import (
	"errors"
	"testing"
)

func TestFDLeasePreservesFirstUnadoptedCloseFailure(t *testing.T) {
	firstError := errors.New("输入 FD 关闭失败")
	closeCalls := 0
	lease, err := NewFDLease(9, func(int) error {
		closeCalls++
		if closeCalls == 1 {
			return firstError
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		if err := lease.ReleaseUnadopted(); !errors.Is(err, firstError) {
			t.Fatalf("首次 FD 关闭错误丢失：%v", err)
		}
	}
	if closeCalls != 1 {
		t.Fatalf("重复关闭未知所有权的 FD：次数=%d", closeCalls)
	}
}

func TestStateInputCleanupRunsInsideLifecycleLock(t *testing.T) {
	var s State
	cleanupCalls := 0
	cleanupInsideLock := false
	started := s.StartWithInputCleanup(9, false, nil, nil, func() error {
		cleanupCalls++
		if s.mu.TryLock() {
			s.mu.Unlock()
		} else {
			cleanupInsideLock = true
		}
		return nil
	})
	if started || cleanupCalls != 1 || !cleanupInsideLock {
		t.Fatalf("输入回收未受生命周期锁保护：started=%v calls=%d insideLock=%v", started, cleanupCalls, cleanupInsideLock)
	}
}

func TestStateInputCleanupFailurePoisonsFutureStartAndStop(t *testing.T) {
	var s State
	releases, opens, cleanupCalls := 0, 0, 0
	firstError := errors.New("输入资源关闭失败")
	started := s.StartWithInputCleanup(9, false, func() { releases++ }, nil, func() error {
		cleanupCalls++
		return firstError
	})
	if started || s.Stop() || s.Stop() {
		t.Fatal("输入资源关闭失败后不能报告启停成功")
	}
	if s.StartWithInputCleanup(10, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
		opens++
		return nil, errors.New("不得执行新资源构造")
	}, func() error { cleanupCalls++; return nil }) {
		t.Fatal("未知输入资源所有权下启动了新代")
	}
	if releases != 2 || opens != 0 || cleanupCalls != 2 || !s.Runtime().IsZero() {
		t.Fatalf("拒绝新代时资源处理错误：releases=%d opens=%d cleanupCalls=%d", releases, opens, cleanupCalls)
	}
	if !errors.Is(s.inputCleanupErr, firstError) {
		t.Fatalf("首次输入清理错误被覆盖：%v", s.inputCleanupErr)
	}
}
