package androidstartup

import "testing"

func TestOwnedStateLateStopCannotCloseNewResource(t *testing.T) {
	var s State
	a := TunOwnership{1, 1, 1}
	b := TunOwnership{1, 2, 2}
	old := &rejectedInputResource{}
	newer := &rejectedInputResource{}
	if !s.StartOwnedWithInputCleanupReport(a, 9, true, nil, func(*OnceLease) (Resource, error) { return old, nil }, nil).Started || !s.StopOwned(a) {
		t.Fatal("A不能正常收尾")
	}
	if !s.StartOwnedWithInputCleanupReport(b, 10, true, nil, func(*OnceLease) (Resource, error) { return newer, nil }, nil).Started {
		t.Fatal("B不能启动")
	}
	before := s.Runtime()
	if s.StopOwned(a) || newer.closes != 0 || s.Runtime() != before {
		t.Fatal("晚到A stop误停B")
	}
	if !s.StopOwned(b) || newer.closes != 1 {
		t.Fatal("B不能由自身身份停止")
	}
}

func TestOwnedStateLegacyStopCannotCloseOwnedResource(t *testing.T) {
	var s State
	owner := TunOwnership{1, 1, 1}
	resource := &rejectedInputResource{}
	if !s.StartOwnedWithInputCleanupReport(owner, 9, true, nil, func(*OnceLease) (Resource, error) { return resource, nil }, nil).Started {
		t.Fatal("启动失败")
	}
	if s.Stop() || resource.closes != 0 {
		t.Fatal("无身份stop误停受管资源")
	}
	if !s.StopOwned(owner) {
		t.Fatal("受管资源停止失败")
	}
}

func TestOwnedStateRejectsReplacementAndCleansOnlyNewInput(t *testing.T) {
	var s State
	a := TunOwnership{1, 1, 1}
	b := TunOwnership{1, 2, 2}
	old := &rejectedInputResource{}
	if !s.StartOwnedWithInputCleanupReport(a, 9, true, nil, func(*OnceLease) (Resource, error) { return old, nil }, nil).Started {
		t.Fatal("A启动失败")
	}
	releases, cleanups, opens := 0, 0, 0
	r := s.StartOwnedWithInputCleanupReport(b, 10, true, func() { releases++ }, func(*OnceLease) (Resource, error) { opens++; return nil, nil }, func() error { cleanups++; return nil })
	if r.Started || r.Entered || r.CleanupUnconfirmed || !r.Running || old.closes != 0 || opens != 0 || releases != 1 || cleanups != 1 {
		t.Fatalf("未收口替换错误: %+v", r)
	}
	if !s.StopOwned(a) {
		t.Fatal("A身份被拒绝请求覆盖")
	}
}

func TestOwnedStateNonVpnIdentityAndFullStampMatch(t *testing.T) {
	var s State
	owner := TunOwnership{1, 2, 3}
	if !s.StartOwnedWithInputCleanupReport(owner, 0, true, nil, nil, nil).Started {
		t.Fatal("非VPN启动失败")
	}
	for _, wrong := range []TunOwnership{{2, 2, 3}, {1, 3, 3}, {1, 2, 4}, {0, 0, 0}} {
		if s.StopOwned(wrong) {
			t.Fatal("不完整身份停止非VPN资源")
		}
	}
	got, ok := s.OwnedIdentity()
	if !ok || got != owner {
		t.Fatal("身份丢失")
	}
	got.Generation = 9
	if !s.StopOwned(owner) {
		t.Fatal("身份快照别名或正常停止失败")
	}
	if _, ok := s.OwnedIdentity(); ok {
		t.Fatal("确认收尾仍保留身份")
	}
}

func TestOwnedStateUnknownReleasePreservesIdentity(t *testing.T) {
	var s State
	owner := TunOwnership{1, 1, 1}
	resource := &rejectedInputResource{}
	if !s.StartOwnedWithInputCleanupReport(owner, 9, true, func() { panic("公开引用释放失败") }, func(*OnceLease) (Resource, error) { return resource, nil }, nil).Started {
		t.Fatal("启动失败")
	}
	if s.StopOwned(owner) {
		t.Fatal("释放未知伪造停止")
	}
	got, ok := s.OwnedIdentity()
	if !ok || got != owner || resource.closes != 1 {
		t.Fatal("未知引用身份丢失")
	}
	if s.StopOwned(owner) || s.Stop() || resource.closes != 1 {
		t.Fatal("重试清洗未知或重复close")
	}
}

func TestOwnedStateOpenPanicKeepsIdentity(t *testing.T) {
	var s State
	owner := TunOwnership{1, 1, 1}
	r := s.StartOwnedWithInputCleanupReport(owner, 9, true, nil, func(*OnceLease) (Resource, error) { panic("公开构造失败") }, nil)
	got, ok := s.OwnedIdentity()
	if r.Started || !r.CleanupUnconfirmed || !r.Entered || !ok || got != owner || s.StopOwned(owner) {
		t.Fatal("构造未知未保留身份")
	}
}

func TestOwnedStateInvalidIdentityCleansWithoutOpening(t *testing.T) {
	for _, owner := range []TunOwnership{{0, 1, 1}, {1, 0, 1}, {1, 1, 0}, {-1, 1, 1}} {
		var s State
		releases, cleanups, opens := 0, 0, 0
		r := s.StartOwnedWithInputCleanupReport(owner, 9, true, func() { releases++ }, func(*OnceLease) (Resource, error) { opens++; return nil, nil }, func() error { cleanups++; return nil })
		if r.Started || r.Entered || r.Running || r.CleanupUnconfirmed || opens != 0 || releases != 1 || cleanups != 1 {
			t.Fatal("非法身份进入构造或漏清理")
		}
	}
}

func TestOwnedStateLegacyStartCannotReplaceOwnedResource(t *testing.T) {
	var s State
	owner := TunOwnership{1, 1, 1}
	resource := &rejectedInputResource{}
	if !s.StartOwnedWithInputCleanupReport(owner, 9, true, nil, func(*OnceLease) (Resource, error) { return resource, nil }, nil).Started {
		t.Fatal("启动失败")
	}
	releases, cleanups, opens := 0, 0, 0
	r := s.StartWithInputCleanupReport(10, true, func() { releases++ }, func(*OnceLease) (Resource, error) { opens++; return nil, nil }, func() error { cleanups++; return nil })
	if r.Started || r.Entered || resource.closes != 0 || opens != 0 || releases != 1 || cleanups != 1 {
		t.Fatal("旧启动旁路误替换资源")
	}
	if !s.StopOwned(owner) {
		t.Fatal("旧请求覆盖身份")
	}
}

func TestOwnedStateReportsCaptureSameOperationIdentity(t *testing.T) {
	var s State
	a := TunOwnership{1, 1, 1}
	b := TunOwnership{1, 2, 2}
	first := s.StartOwnedWithInputCleanupReport(a, 0, true, nil, nil, nil)
	if !first.HasOwnership || first.Ownership != a {
		t.Fatal("start未捕获身份")
	}
	wrong := s.StopOwnedReport(b)
	if wrong.Stopped || wrong.Matched || !wrong.HasOwnership || wrong.Ownership != a || !wrong.Running {
		t.Fatal("错代stop混淆剩余资源")
	}
	stopped := s.StopOwnedReport(a)
	if !stopped.Stopped || !stopped.Matched || stopped.HasOwnership || stopped.Running {
		t.Fatal("stop结果未捕获确认收尾")
	}
	s.StartOwnedWithInputCleanupReport(b, 0, true, nil, nil, nil)
	if first.Ownership != a || wrong.Ownership != a || stopped.HasOwnership {
		t.Fatal("后续状态改写旧回执")
	}
	if !s.StopOwned(b) {
		t.Fatal("B收尾失败")
	}
}

func TestOwnedStateNonVpnReleaseUnknownPreservesIdentity(t *testing.T) {
	var s State
	owner := TunOwnership{1, 2, 3}
	report := s.StartOwnedWithInputCleanupReport(owner, 0, true, func() { panic("公开非VPN引用释放失败") }, nil, nil)
	got, ok := s.OwnedIdentity()
	if report.Started || !report.CleanupUnconfirmed || !report.RetainsLease || !report.HasOwnership || report.Ownership != owner || !ok || got != owner || s.StopOwned(owner) || s.Stop() {
		t.Fatal("非VPN引用未知丢失身份")
	}
}
