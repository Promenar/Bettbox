package main

import (
	"core/androidstartup"
	"testing"
)

func configuredReservationFixture(t *testing.T) (*androidConfigCoordinator, *fixtureAndroidConfigDriver) {
	t.Helper()
	d := &fixtureAndroidConfigDriver{initialized: true}
	c := newAndroidConfigCoordinatorForTest(d)
	c.commitLocked(c.epoch, 0, fixtureMutation(t, androidConfigKindState, `{"bypass-domain":["public.invalid"],"vpn-props":{"enable":true}}`))
	if result := c.commitLocked(c.epoch, 0, fixtureMutation(t, androidConfigKindSetup, fixtureSetupJSON(t))); result.Outcome != androidConfigOutcomeApplied {
		t.Fatal("公开配置未完成")
	}
	return c, d
}

func TestAndroidConfigTunReservationRejectsMutationBeforeEntry(t *testing.T) {
	c, d := configuredReservationFixture(t)
	r, code := c.reserveTunLocked(c.epoch, c.lastApplied)
	if r == nil || code != "" {
		t.Fatalf("配置预留失败: %s", code)
	}
	result := c.commitLocked(c.epoch, c.lastApplied, fixtureMutation(t, androidConfigKindUpdate, `{}`))
	if result.ErrorCode != "tunConfigurationReserved" || result.Phase != androidConfigPhaseNotEntered || d.updateCall != 0 || c.lastAttempted != 1 {
		t.Fatalf("预留后配置仍进入副作用: %+v", result)
	}
}

func TestAndroidConfigTunReservationRunningRetainsUntilCheckedStop(t *testing.T) {
	c, _ := configuredReservationFixture(t)
	r, _ := c.reserveTunLocked(c.epoch, c.lastApplied)
	r.options.BypassDomain[0] = "changed.invalid"
	r.options.Enable = false // 消费者修改options不能改变已预留的模式。
	if c.options.BypassDomain[0] != "public.invalid" {
		t.Fatal("预留泄露配置别名")
	}
	report := androidstartup.StartReport{Started: true, Entered: true, Running: true, RetainsResource: true, RetainsLease: true}
	if code := c.finishTunStartLocked(r, report); code != "" {
		t.Fatal(code)
	}
	if _, code := c.reserveTunLocked(c.epoch, c.lastApplied); code != androidConfigErrorTunReserved {
		t.Fatal("running没有保留预留")
	}
	if code := c.finishTunStopLocked(r, true); code != "" {
		t.Fatal(code)
	}
	if result := c.commitLocked(c.epoch, 1, fixtureMutation(t, androidConfigKindUpdate, `{}`)); result.ConfigRevision != 2 {
		t.Fatal("确认stop后不能提交配置")
	}
	newer, code := c.reserveTunLocked(c.epoch, 2)
	if newer == nil || code != "" {
		t.Fatal("新版本不能预留")
	}
	if code := c.finishTunStopLocked(r, true); code != androidConfigErrorTunReservation || c.tunReservation != newer || c.blocked {
		t.Fatal("旧stop污染新预留")
	}
}

func TestAndroidConfigTunReservationCleanFailureAllowsRetry(t *testing.T) {
	c, _ := configuredReservationFixture(t)
	r, _ := c.reserveTunLocked(c.epoch, c.lastApplied)
	if code := c.finishTunStartLocked(r, androidstartup.StartReport{Entered: true, Code: "openFailed"}); code != "" || c.tunReservation != nil {
		t.Fatal("干净失败没有解除预留")
	}
	if code := c.finishTunStartLocked(r, androidstartup.StartReport{}); code != androidConfigErrorTunReservation || c.blocked {
		t.Fatal("旧回执污染配置")
	}
	if _, code := c.reserveTunLocked(c.epoch, 1); code != "" {
		t.Fatal("干净失败不能重试")
	}
}

func TestAndroidConfigTunReservationUnknownIsSticky(t *testing.T) {
	for _, report := range []androidstartup.StartReport{
		{},
		{Started: true, Entered: true, Running: true, RetainsResource: true},
		{Entered: true, Code: "openFailed", RetainsLease: true},
		{Started: true, Entered: true, Running: true, RetainsResource: true, CleanupUnconfirmed: true},
		{Started: true, Running: true, RetainsResource: true},
	} {
		c, _ := configuredReservationFixture(t)
		r, _ := c.reserveTunLocked(c.epoch, 1)
		if code := c.finishTunStartLocked(r, report); code != androidConfigErrorTunUnknown || !c.blocked || c.tunReservation != r {
			t.Fatal("未知报告丢失责任")
		}
		if code := c.finishTunStopLocked(r, true); code == "" || !c.blocked || c.tunReservation != r {
			t.Fatal("后续true清洗未知")
		}
	}
}

func TestAndroidConfigTunReservationFailedStopBlocks(t *testing.T) {
	c, _ := configuredReservationFixture(t)
	r, _ := c.reserveTunLocked(c.epoch, 1)
	c.finishTunStartLocked(r, androidstartup.StartReport{Started: true, Entered: true, Running: true, RetainsResource: true, RetainsLease: true})
	if code := c.finishTunStopLocked(r, false); code != androidConfigErrorTunUnknown || !c.blocked || c.tunReservation != r {
		t.Fatal("失败stop丢失责任")
	}
	if code := c.finishTunStopLocked(r, true); code != androidConfigErrorTunUnknown || c.tunReservation != r {
		t.Fatal("重复stop清洗未知")
	}
}

func TestAndroidConfigTunReservationRejectsWrongStampAndUnconfigured(t *testing.T) {
	c, _ := configuredReservationFixture(t)
	for _, stamp := range [][2]int64{{c.epoch + 1, 1}, {c.epoch, 0}, {c.epoch, 2}} {
		if r, code := c.reserveTunLocked(stamp[0], stamp[1]); r != nil || code == "" || c.tunReservation != nil {
			t.Fatal("错误版本获得预留")
		}
	}
	unconfigured := newAndroidConfigCoordinatorForTest(&fixtureAndroidConfigDriver{initialized: true})
	if r, code := unconfigured.reserveTunLocked(unconfigured.epoch, 0); r != nil || code == "" {
		t.Fatal("未配置获得预留")
	}
	r, _ := c.reserveTunLocked(c.epoch, 1)
	c.lastApplied++ // 模拟尚未收敛的旧旁路，完成核验不能伪造成功。
	if code := c.finishTunStartLocked(r, androidstartup.StartReport{Started: true, Entered: true, Running: true, RetainsResource: true, RetainsLease: true}); code != androidConfigErrorTunUnknown || !c.blocked {
		t.Fatal("版本漂移未阻断")
	}
}

func TestAndroidConfigTunReservationNonVpnModeAcceptsRealStateReport(t *testing.T) {
	c, _ := configuredReservationFixture(t)
	if result := c.commitLocked(c.epoch, 1, fixtureMutation(t, androidConfigKindState, `{"vpn-props":{"enable":false}}`)); result.Outcome != androidConfigOutcomeApplied {
		t.Fatal("公开非VPN模式配置失败")
	}
	r, code := c.reserveTunLocked(c.epoch, 2)
	if r == nil || code != "" {
		t.Fatal("非VPN模式预留失败")
	}
	var s androidstartup.State
	report := s.StartWithInputCleanupReport(0, true, nil, nil, nil)
	if !report.Started || !report.Running || report.Entered || report.RetainsResource || report.RetainsLease {
		t.Fatal("实际fd0报告与合同不符")
	}
	if code := c.finishTunStartLocked(r, report); code != "" || c.blocked || !r.running {
		t.Fatalf("实际非VPN报告被误拒: %s", code)
	}
	if code := c.finishTunStopLocked(r, s.Stop()); code != "" || c.tunReservation != nil {
		t.Fatal("非VPN模式不能确认停止")
	}
}

func TestAndroidConfigTunReservationRejectsModeMismatch(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		c, _ := configuredReservationFixture(t)
		if !enabled {
			c.commitLocked(c.epoch, 1, fixtureMutation(t, androidConfigKindState, `{"vpn-props":{"enable":false}}`))
		}
		r, _ := c.reserveTunLocked(c.epoch, c.lastApplied)
		report := androidstartup.StartReport{Started: true, Running: true}
		if !enabled {
			report.Entered = true
			report.RetainsResource = true
			report.RetainsLease = true
		}
		if code := c.finishTunStartLocked(r, report); code != androidConfigErrorTunUnknown || !c.blocked || c.tunReservation != r {
			t.Fatal("模式不匹配报告伪造成功")
		}
	}
}
