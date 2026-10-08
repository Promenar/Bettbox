package androidstartup

import (
	"errors"
	"sync"
	"testing"
	"time"
)

type fakeResource struct {
	closed int
	lease  *OnceLease
}

func (r *fakeResource) Close() error {
	r.closed++
	if r.lease != nil {
		r.lease.Release()
	}
	return nil
}

func TestNilConfigDoesNotReenterAndReleases(t *testing.T) {
	var s State
	releases := 0
	done := make(chan bool, 1)
	go func() {
		done <- s.Start(7, false, func() { releases++ }, func(*OnceLease) (Resource, error) { t.Error("未配置不得创建资源"); return nil, nil })
	}()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("未配置不得成功")
		}
	case <-time.After(time.Second):
		t.Fatal("状态锁重入")
	}
	if releases != 1 || !s.Runtime().IsZero() {
		t.Fatal("失败未清理或提交了运行时间")
	}
}

func TestStartOutcomesAndRepeatedStop(t *testing.T) {
	for _, outcome := range []string{"error", "partial-error", "nil", "success"} {
		t.Run(outcome, func(t *testing.T) {
			var s State
			releases := 0
			resource := &fakeResource{}
			ok := s.Start(7, true, func() { releases++ }, func(lease *OnceLease) (Resource, error) {
				resource.lease = lease
				if !s.runtime.IsZero() {
					t.Error("open 完成前提交时间")
				}
				switch outcome {
				case "error":
					return nil, errors.New("虚构失败")
				case "partial-error":
					return resource, errors.New("虚构失败")
				case "nil":
					return nil, nil
				default:
					return resource, nil
				}
			})
			if ok != (outcome == "success") {
				t.Fatal("启动真假状态错误")
			}
			if ok && (s.Runtime().IsZero() || releases != 0) {
				t.Fatal("成功必须持有回调且提交时间")
			}
			if !ok && (!s.Runtime().IsZero() || releases != 1) {
				t.Fatal("失败清理错误")
			}
			s.Stop()
			s.Stop()
			if !s.Runtime().IsZero() || releases != 1 {
				t.Fatal("停止未清理或重复释放")
			}
			wantClose := 0
			if outcome == "success" || outcome == "partial-error" {
				wantClose = 1
			}
			if resource.closed != wantClose {
				t.Fatal("资源关闭次数错误")
			}
		})
	}
}

func TestInvalidFDNoOpenAndRuntimeGetterSynchronization(t *testing.T) {
	var s State
	releases := 0
	for _, fd := range []int{-1, -7} {
		if s.Start(fd, true, func() { releases++ }, func(*OnceLease) (Resource, error) { t.Fatal("无效 FD 不得创建资源"); return nil, nil }) {
			t.Fatal("无效 FD 成功")
		}
	}
	if releases != 2 {
		t.Fatal("JNI 已移交引用必须释放")
	}
	entered, unblock := make(chan struct{}), make(chan struct{})
	startDone := make(chan bool, 1)
	go func() {
		startDone <- s.Start(7, true, nil, func(*OnceLease) (Resource, error) { close(entered); <-unblock; return &fakeResource{}, nil })
	}()
	<-entered
	getDone := make(chan time.Time, 1)
	go func() { getDone <- s.Runtime() }()
	select {
	case <-getDone:
		t.Fatal("getter 越过启动事务")
	case <-time.After(10 * time.Millisecond):
	}
	close(unblock)
	if !<-startDone {
		t.Fatal("启动失败")
	}
	if (<-getDone).IsZero() {
		t.Fatal("getter 未读到已提交时间")
	}
	s.Stop()
}

func TestZeroFDCommitsNonVPNWithoutOpenOrLease(t *testing.T) {
	var s State
	releases := 0
	opens := 0
	open := func(*OnceLease) (Resource, error) { opens++; return &fakeResource{}, nil }
	if s.Start(0, false, func() { releases++ }, open) || !s.Runtime().IsZero() {
		t.Fatal("配置未就绪不得提交非 VPN 状态")
	}
	before := time.Now()
	if !s.Start(0, true, func() { releases++ }, open) {
		t.Fatal("配置就绪的非 VPN 模式应成功")
	}
	started := s.Runtime()
	if started.IsZero() || started.Before(before) || opens != 0 || s.lease != nil || s.resource != nil {
		t.Fatal("非 VPN 启动错误创建 listener/lease 或未更新时间")
	}
	if releases != 2 {
		t.Fatal("误交 callback 未恰好释放一次")
	}
	s.Stop()
	s.Stop()
	if !s.Runtime().IsZero() || releases != 2 {
		t.Fatal("非 VPN 停止重复释放或未清空时间")
	}
	if !s.Start(0, true, nil, open) || opens != 0 {
		t.Fatal("非 VPN 模式不要求 callback，也不调用 FD open/dup 路径")
	}
	s.Stop()
}

func TestOnceLeaseConcurrentCleanup(t *testing.T) {
	count := 0
	lease := NewOnceLease(func() { count++ })
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); lease.Release() }()
	}
	wg.Wait()
	if count != 1 {
		t.Fatal("回调未恰好释放一次")
	}
}

func TestSnapshotReleasesConfigLockAndCopiesMutableInput(t *testing.T) {
	var configLock sync.Mutex
	input := []string{"虚构设备"}
	copy := Snapshot(&configLock, func() []string { return append([]string(nil), input...) })
	input[0] = "新设备"
	if copy[0] != "虚构设备" {
		t.Fatal("快照仍引用配置切片")
	}
	if !configLock.TryLock() {
		t.Fatal("读取后未释放配置锁")
	}
	configLock.Unlock()
}

func TestFDAdoptionBeforeAndAfterListenerFailure(t *testing.T) {
	for _, adopted := range []bool{false, true} {
		t.Run(map[bool]string{false: "tunNew前失败", true: "采纳后失败"}[adopted], func(t *testing.T) {
			detachedClosed, nativeClosed := 0, 0
			lease, err := NewFDLease(9, func(fd int) error {
				if fd != 9 {
					t.Errorf("关闭了未移交的 FD：%d", fd)
				}
				detachedClosed++
				return nil
			})
			if err != nil {
				t.Fatal(err)
			}
			// 采纳通知必须在 NativeTun 进入 listener 的关闭列表之后发生。
			if adopted {
				lease.Adopt()
				nativeClosed++
			}
			lease.ReleaseUnadopted()
			lease.ReleaseUnadopted()
			if adopted && (detachedClosed != 0 || nativeClosed != 1) {
				t.Fatal("采纳后双重关闭")
			}
			if !adopted && detachedClosed != 1 {
				t.Fatal("采纳前失败泄漏移交的 FD")
			}
		})
	}
}

func TestSuccessfulFDAdoptionClosedOnlyAtStop(t *testing.T) {
	var s State
	unadoptedClosed, nativeClosed, releases := 0, 0, 0
	fdLease, _ := NewFDLease(9, func(int) error { unadoptedClosed++; return nil })
	resource := &ownedFDResource{close: func() { nativeClosed++ }}
	if !s.Start(7, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
		fdLease.Adopt()
		defer fdLease.ReleaseUnadopted()
		return resource, nil
	}) {
		t.Fatal("启动失败")
	}
	if unadoptedClosed != 0 || nativeClosed != 0 || releases != 0 {
		t.Fatal("运行中提前关闭")
	}
	s.Stop()
	s.Stop()
	if unadoptedClosed != 0 || nativeClosed != 1 || releases != 1 {
		t.Fatal("停止所有权错误")
	}
}

type ownedFDResource struct{ close func() }

func (r *ownedFDResource) Close() error { r.close(); return nil }
