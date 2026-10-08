package androidstartup

import (
	"strconv"
	"testing"
)

func TestJNIReleaseConfirmationOnlyExactSuccess(t *testing.T) {
	for _, code := range []int{0, 2, -1, 3, 2147483647} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			if ConfirmJNIRelease(code) == nil {
				t.Fatal("非确认状态被接受为释放成功")
			}
		})
	}
	if ConfirmJNIRelease(1) != nil {
		t.Fatal("确认释放被误拒绝")
	}
}

type releaseConfirmationResource struct{ closes int }

func (r *releaseConfirmationResource) Close() error { r.closes++; return nil }

func TestJNIReleaseConfirmationRealStateRetainsFailure(t *testing.T) {
	for _, code := range []int{0, 2, -1} {
		s := State{}
		r := &releaseConfirmationResource{}
		releases := 0
		if !s.Start(5, true, func() {
			releases++
			if err := ConfirmJNIRelease(code); err != nil {
				panic(err)
			}
		}, func(*OnceLease) (Resource, error) { return r, nil }) {
			t.Fatal("公开资源未启动")
		}
		if s.Stop() || s.Stop() {
			t.Fatal("未知JNI释放被报告为停止成功")
		}
		if r.closes != 1 || releases != 1 || s.lease == nil || !s.Runtime().IsZero() {
			t.Fatal("未知释放被重试、责任丢失或已关闭资源运行时间未清理")
		}
		newReleases := 0
		report := s.StartWithInputCleanupReport(6, true, func() { newReleases++ }, func(*OnceLease) (Resource, error) {
			t.Fatal("未知释放后进入新资源构造")
			return nil, nil
		}, nil)
		if report.Started || !report.CleanupUnconfirmed || !report.RetainsLease || report.Code != startCodeReleasePanic || newReleases != 1 {
			t.Fatal("未知释放未粘滞阻断新代")
		}
	}
}

func TestJNIReleaseConfirmationRealStateAcceptsConfirmed(t *testing.T) {
	s := State{}
	r := &releaseConfirmationResource{}
	releases := 0
	if !s.Start(5, true, func() {
		releases++
		if err := ConfirmJNIRelease(1); err != nil {
			panic(err)
		}
	}, func(*OnceLease) (Resource, error) { return r, nil }) {
		t.Fatal("公开资源未启动")
	}
	if !s.Stop() || !s.Stop() || r.closes != 1 || releases != 1 || s.lease != nil || !s.Runtime().IsZero() {
		t.Fatal("确认释放未完成一次收口")
	}
}
