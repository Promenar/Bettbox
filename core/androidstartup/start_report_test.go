package androidstartup

import (
	"errors"
	"testing"
)

const (
	wantStartCodeNotReady            = "notReady"
	wantStartCodeOpenFailed          = "openFailed"
	wantStartCodeResourceCloseFailed = "resourceCloseFailed"
	wantStartCodeInputCleanupFailed  = "inputCleanupFailed"
	wantStartCodeOpenPanic           = "openPanic"
	wantStartCodeResourceClosePanic  = "resourceClosePanic"
	wantStartCodeInputCleanupPanic   = "inputCleanupPanic"
	wantStartCodeReleasePanic        = "releasePanic"
)

type reportResource struct {
	closeCalls int
	close      func(call int) error
}

func (r *reportResource) Close() error {
	r.closeCalls++
	if r.close == nil {
		return nil
	}
	return r.close(r.closeCalls)
}

func assertStartReport(t *testing.T, got StartReport, want StartReport) {
	t.Helper()
	if got != want {
		t.Fatalf("启动报告不符：got=%+v want=%+v", got, want)
	}
}

func TestStartReportCleanPreflightRejection(t *testing.T) {
	var state State
	releases, cleanupCalls := 0, 0
	report := state.StartWithInputCleanupReport(9, false, func() { releases++ }, nil, func() error {
		cleanupCalls++
		return nil
	})
	assertStartReport(t, report, StartReport{Code: wantStartCodeNotReady})
	if releases != 1 || cleanupCalls != 1 {
		t.Fatalf("前置拒绝未完整处理输入：releases=%d cleanup=%d", releases, cleanupCalls)
	}
}

func TestStartReportCleanOpenFailure(t *testing.T) {
	var state State
	releases, cleanupCalls, opens := 0, 0, 0
	report := state.StartWithInputCleanupReport(9, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
		opens++
		return nil, errors.New("公开构造失败")
	}, func() error {
		cleanupCalls++
		return nil
	})
	assertStartReport(t, report, StartReport{Entered: true, Code: wantStartCodeOpenFailed})
	if releases != 1 || cleanupCalls != 1 || opens != 1 {
		t.Fatalf("干净构造失败资源处理错误：releases=%d cleanup=%d opens=%d", releases, cleanupCalls, opens)
	}
}

func TestStartReportSuccessRetainsRunningResource(t *testing.T) {
	var state State
	resource := &reportResource{}
	releases := 0
	report := state.StartWithInputCleanupReport(9, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
		return resource, nil
	}, func() error { return nil })
	assertStartReport(t, report, StartReport{
		Started:         true,
		Entered:         true,
		RetainsResource: true,
		RetainsLease:    true,
		Running:         true,
	})
	if releases != 0 || resource.closeCalls != 0 {
		t.Fatalf("成功启动提前释放资源：releases=%d closes=%d", releases, resource.closeCalls)
	}
}

func TestStartReportPartialResourceCloseFailureIsUnknown(t *testing.T) {
	var state State
	resource := &reportResource{close: func(int) error { return errors.New("公开关闭失败") }}
	releases := 0
	report := state.StartWithInputCleanupReport(9, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
		return resource, errors.New("公开部分构造失败")
	}, func() error { return nil })
	assertStartReport(t, report, StartReport{
		Entered:            true,
		CleanupUnconfirmed: true,
		RetainsResource:    true,
		RetainsLease:       true,
		Code:               wantStartCodeResourceCloseFailed,
	})
	if releases != 0 || resource.closeCalls != 1 {
		t.Fatalf("未知部分资源责任被提前释放或重复关闭：releases=%d closes=%d", releases, resource.closeCalls)
	}
}

func TestStartReportInputCleanupFailureIsUnknown(t *testing.T) {
	var state State
	releases, cleanupCalls := 0, 0
	report := state.StartWithInputCleanupReport(9, false, func() { releases++ }, nil, func() error {
		cleanupCalls++
		return errors.New("公开输入关闭失败")
	})
	assertStartReport(t, report, StartReport{
		CleanupUnconfirmed: true,
		Code:               wantStartCodeInputCleanupFailed,
	})
	if releases != 1 || cleanupCalls != 1 {
		t.Fatalf("输入关闭失败路径调用次数错误：releases=%d cleanup=%d", releases, cleanupCalls)
	}
}

func TestStartReportOldResourceCloseFailurePreservesRunningOwner(t *testing.T) {
	var state State
	oldResource := &reportResource{close: func(int) error { return errors.New("公开旧资源关闭失败") }}
	oldReleases, newReleases, newCleanup, newOpens := 0, 0, 0, 0
	first := state.StartWithInputCleanupReport(9, true, func() { oldReleases++ }, func(*OnceLease) (Resource, error) {
		return oldResource, nil
	}, func() error { return nil })
	if !first.Started {
		t.Fatal("旧运行代夹具未启动")
	}
	second := state.StartWithInputCleanupReport(10, true, func() { newReleases++ }, func(*OnceLease) (Resource, error) {
		newOpens++
		return &reportResource{}, nil
	}, func() error {
		newCleanup++
		return nil
	})
	assertStartReport(t, second, StartReport{
		CleanupUnconfirmed: true,
		RetainsResource:    true,
		RetainsLease:       true,
		Running:            true,
		Code:               wantStartCodeResourceCloseFailed,
	})
	if oldResource.closeCalls != 1 || oldReleases != 0 || newReleases != 1 || newCleanup != 1 || newOpens != 0 {
		t.Fatalf("旧运行代关闭失败后责任错误：oldCloses=%d oldRelease=%d newRelease=%d cleanup=%d opens=%d",
			oldResource.closeCalls, oldReleases, newReleases, newCleanup, newOpens)
	}
}

func TestStartReportBlockedStateStillCleansNewInput(t *testing.T) {
	var state State
	firstCleanup, nextCleanup, nextReleases, nextOpens := 0, 0, 0, 0
	state.StartWithInputCleanupReport(9, false, nil, nil, func() error {
		firstCleanup++
		return errors.New("公开首次输入关闭失败")
	})
	report := state.StartWithInputCleanupReport(10, true, func() { nextReleases++ }, func(*OnceLease) (Resource, error) {
		nextOpens++
		return &reportResource{}, nil
	}, func() error {
		nextCleanup++
		return nil
	})
	assertStartReport(t, report, StartReport{
		CleanupUnconfirmed: true,
		Code:               wantStartCodeInputCleanupFailed,
	})
	if firstCleanup != 1 || nextCleanup != 1 || nextReleases != 1 || nextOpens != 0 {
		t.Fatalf("阻断状态未清理新输入：first=%d next=%d releases=%d opens=%d",
			firstCleanup, nextCleanup, nextReleases, nextOpens)
	}
}

func TestStartReportFirstCloseFailureCannotBeWashedByLaterNil(t *testing.T) {
	var state State
	resource := &reportResource{close: func(call int) error {
		if call == 1 {
			return errors.New("公开首次关闭失败")
		}
		return nil
	}}
	oldReleases := 0
	if !state.StartWithInputCleanupReport(9, true, func() { oldReleases++ }, func(*OnceLease) (Resource, error) {
		return resource, nil
	}, func() error { return nil }).Started {
		t.Fatal("运行代夹具未启动")
	}

	for _, fd := range []int{10, 11} {
		releases, cleanupCalls, opens := 0, 0, 0
		report := state.StartWithInputCleanupReport(fd, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
			opens++
			return &reportResource{}, nil
		}, func() error {
			cleanupCalls++
			return nil
		})
		assertStartReport(t, report, StartReport{
			CleanupUnconfirmed: true,
			RetainsResource:    true,
			RetainsLease:       true,
			Running:            true,
			Code:               wantStartCodeResourceCloseFailed,
		})
		if releases != 1 || cleanupCalls != 1 || opens != 0 {
			t.Fatalf("阻断后的输入处理错误：fd=%d releases=%d cleanup=%d opens=%d", fd, releases, cleanupCalls, opens)
		}
	}
	if resource.closeCalls != 1 || oldReleases != 0 {
		t.Fatalf("首次unknown被后续nil洗掉：closes=%d oldRelease=%d", resource.closeCalls, oldReleases)
	}
}

func TestStartReportOpenPanicRetainsLeaseAndBlocks(t *testing.T) {
	var state State
	releases, cleanupCalls := 0, 0
	report := state.StartWithInputCleanupReport(9, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
		panic("公开open panic")
	}, func() error {
		cleanupCalls++
		return nil
	})
	assertStartReport(t, report, StartReport{
		Entered:            true,
		CleanupUnconfirmed: true,
		RetainsLease:       true,
		Code:               wantStartCodeOpenPanic,
	})
	if releases != 0 || cleanupCalls != 1 {
		t.Fatalf("open panic伪造释放或跳过输入清理：releases=%d cleanup=%d", releases, cleanupCalls)
	}

	nextCleanup, nextReleases, nextOpens := 0, 0, 0
	next := state.StartWithInputCleanupReport(10, true, func() { nextReleases++ }, func(*OnceLease) (Resource, error) {
		nextOpens++
		return &reportResource{}, nil
	}, func() error {
		nextCleanup++
		return nil
	})
	assertStartReport(t, next, StartReport{
		CleanupUnconfirmed: true,
		RetainsLease:       true,
		Code:               wantStartCodeOpenPanic,
	})
	if nextCleanup != 1 || nextReleases != 1 || nextOpens != 0 {
		t.Fatalf("open panic后接受新启动或遗漏清理：cleanup=%d releases=%d opens=%d", nextCleanup, nextReleases, nextOpens)
	}
}

func TestStartReportResourceClosePanicIsSticky(t *testing.T) {
	var state State
	resource := &reportResource{close: func(int) error { panic("公开close panic") }}
	oldReleases := 0
	if !state.StartWithInputCleanupReport(9, true, func() { oldReleases++ }, func(*OnceLease) (Resource, error) {
		return resource, nil
	}, func() error { return nil }).Started {
		t.Fatal("运行代夹具未启动")
	}

	for _, fd := range []int{10, 11} {
		releases, cleanupCalls, opens := 0, 0, 0
		report := state.StartWithInputCleanupReport(fd, true, func() { releases++ }, func(*OnceLease) (Resource, error) {
			opens++
			return &reportResource{}, nil
		}, func() error {
			cleanupCalls++
			return nil
		})
		assertStartReport(t, report, StartReport{
			CleanupUnconfirmed: true,
			RetainsResource:    true,
			RetainsLease:       true,
			Running:            true,
			Code:               wantStartCodeResourceClosePanic,
		})
		if releases != 1 || cleanupCalls != 1 || opens != 0 {
			t.Fatalf("close panic后输入处理错误：fd=%d releases=%d cleanup=%d opens=%d", fd, releases, cleanupCalls, opens)
		}
	}
	if resource.closeCalls != 1 || oldReleases != 0 {
		t.Fatalf("close panic后重试关闭或释放旧lease：closes=%d releases=%d", resource.closeCalls, oldReleases)
	}
}

func TestStartReportInputCleanupPanicIsSticky(t *testing.T) {
	var state State
	releases, cleanupCalls := 0, 0
	report := state.StartWithInputCleanupReport(9, false, func() { releases++ }, nil, func() error {
		cleanupCalls++
		panic("公开input cleanup panic")
	})
	assertStartReport(t, report, StartReport{
		CleanupUnconfirmed: true,
		Code:               wantStartCodeInputCleanupPanic,
	})
	if releases != 1 || cleanupCalls != 1 {
		t.Fatalf("input cleanup panic路径调用次数错误：releases=%d cleanup=%d", releases, cleanupCalls)
	}

	nextCleanup, nextReleases := 0, 0
	next := state.StartWithInputCleanupReport(10, false, func() { nextReleases++ }, nil, func() error {
		nextCleanup++
		return nil
	})
	assertStartReport(t, next, StartReport{
		CleanupUnconfirmed: true,
		Code:               wantStartCodeInputCleanupPanic,
	})
	if nextCleanup != 1 || nextReleases != 1 {
		t.Fatalf("input cleanup panic后遗漏新输入清理：cleanup=%d releases=%d", nextCleanup, nextReleases)
	}
}

func TestStartReportReleasePanicRetainsLeaseAndBlocks(t *testing.T) {
	var state State
	cleanupCalls := 0
	report := state.StartWithInputCleanupReport(9, false, func() { panic("公开release panic") }, nil, func() error {
		cleanupCalls++
		return nil
	})
	assertStartReport(t, report, StartReport{
		CleanupUnconfirmed: true,
		RetainsLease:       true,
		Code:               wantStartCodeReleasePanic,
	})
	if cleanupCalls != 1 {
		t.Fatalf("release panic后未执行输入清理：cleanup=%d", cleanupCalls)
	}

	nextCleanup, nextReleases, nextOpens := 0, 0, 0
	next := state.StartWithInputCleanupReport(10, true, func() { nextReleases++ }, func(*OnceLease) (Resource, error) {
		nextOpens++
		return &reportResource{}, nil
	}, func() error {
		nextCleanup++
		return nil
	})
	assertStartReport(t, next, StartReport{
		CleanupUnconfirmed: true,
		RetainsLease:       true,
		Code:               wantStartCodeReleasePanic,
	})
	if nextCleanup != 1 || nextReleases != 1 || nextOpens != 0 {
		t.Fatalf("release panic后接受新启动或遗漏清理：cleanup=%d releases=%d opens=%d", nextCleanup, nextReleases, nextOpens)
	}
}

func TestProductionReportInputFailurePrecedesResourceCloseFailure(t *testing.T) {
	var state State
	resource := &reportResource{close: func(int) error { return errors.New("公开资源关闭失败") }}
	oldReleases, inputCleanupCalls := 0, 0
	report := state.StartWithInputCleanupReport(9, true, func() { oldReleases++ }, func(*OnceLease) (Resource, error) {
		return resource, nil
	}, func() error {
		inputCleanupCalls++
		return errors.New("公开输入关闭失败")
	})
	assertStartReport(t, report, StartReport{
		Entered:            true,
		CleanupUnconfirmed: true,
		RetainsResource:    true,
		RetainsLease:       true,
		Running:            true,
		Code:               wantStartCodeInputCleanupFailed,
	})
	if resource.closeCalls != 1 || oldReleases != 0 || inputCleanupCalls != 1 {
		t.Fatalf("混合关闭失败责任错误：closes=%d releases=%d inputCleanup=%d",
			resource.closeCalls, oldReleases, inputCleanupCalls)
	}

	nextCleanup, nextReleases, nextOpens := 0, 0, 0
	next := state.StartWithInputCleanupReport(10, true, func() { nextReleases++ }, func(*OnceLease) (Resource, error) {
		nextOpens++
		return &reportResource{}, nil
	}, func() error {
		nextCleanup++
		return nil
	})
	assertStartReport(t, next, StartReport{
		CleanupUnconfirmed: true,
		RetainsResource:    true,
		RetainsLease:       true,
		Running:            true,
		Code:               wantStartCodeInputCleanupFailed,
	})
	if resource.closeCalls != 1 || nextCleanup != 1 || nextReleases != 1 || nextOpens != 0 {
		t.Fatalf("混合关闭失败未保持首次原因或清理新输入：closes=%d cleanup=%d releases=%d opens=%d",
			resource.closeCalls, nextCleanup, nextReleases, nextOpens)
	}
}

func TestProductionReportOldCloseFailurePrecedesNewInputFailure(t *testing.T) {
	var state State
	oldResource := &reportResource{close: func(int) error { return errors.New("公开旧资源关闭失败") }}
	oldReleases := 0
	if !state.StartWithInputCleanupReport(9, true, func() { oldReleases++ }, func(*OnceLease) (Resource, error) {
		return oldResource, nil
	}, func() error { return nil }).Started {
		t.Fatal("旧运行代夹具未启动")
	}

	newReleases, newCleanup, newOpens := 0, 0, 0
	report := state.StartWithInputCleanupReport(10, true, func() { newReleases++ }, func(*OnceLease) (Resource, error) {
		newOpens++
		return &reportResource{}, nil
	}, func() error {
		newCleanup++
		return errors.New("公开新输入关闭失败")
	})
	assertStartReport(t, report, StartReport{
		CleanupUnconfirmed: true,
		RetainsResource:    true,
		RetainsLease:       true,
		Running:            true,
		Code:               wantStartCodeResourceCloseFailed,
	})
	if oldResource.closeCalls != 1 || oldReleases != 0 || newReleases != 1 || newCleanup != 1 || newOpens != 0 {
		t.Fatalf("旧资源失败与新输入失败责任错误：oldCloses=%d oldReleases=%d newReleases=%d cleanup=%d opens=%d",
			oldResource.closeCalls, oldReleases, newReleases, newCleanup, newOpens)
	}
}

func TestProductionReportInputFailurePrecedesReleasePanic(t *testing.T) {
	var state State
	resource := &reportResource{}
	releaseCalls, inputCleanupCalls := 0, 0
	report := state.StartWithInputCleanupReport(9, true, func() {
		releaseCalls++
		panic("公开release panic")
	}, func(*OnceLease) (Resource, error) {
		return resource, nil
	}, func() error {
		inputCleanupCalls++
		return errors.New("公开输入关闭失败")
	})
	assertStartReport(t, report, StartReport{
		Entered:            true,
		CleanupUnconfirmed: true,
		RetainsLease:       true,
		Code:               wantStartCodeInputCleanupFailed,
	})
	if resource.closeCalls != 1 || releaseCalls != 1 || inputCleanupCalls != 1 {
		t.Fatalf("输入失败叠加release panic责任错误：closes=%d releases=%d inputCleanup=%d",
			resource.closeCalls, releaseCalls, inputCleanupCalls)
	}

	nextCleanup, nextReleases, nextOpens := 0, 0, 0
	next := state.StartWithInputCleanupReport(10, true, func() { nextReleases++ }, func(*OnceLease) (Resource, error) {
		nextOpens++
		return &reportResource{}, nil
	}, func() error {
		nextCleanup++
		return nil
	})
	assertStartReport(t, next, StartReport{
		CleanupUnconfirmed: true,
		RetainsLease:       true,
		Code:               wantStartCodeInputCleanupFailed,
	})
	if releaseCalls != 1 || nextCleanup != 1 || nextReleases != 1 || nextOpens != 0 {
		t.Fatalf("release panic混合失败未保持首次原因或清理新输入：oldReleases=%d cleanup=%d releases=%d opens=%d",
			releaseCalls, nextCleanup, nextReleases, nextOpens)
	}
}
