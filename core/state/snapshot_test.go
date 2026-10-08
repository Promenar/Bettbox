package state

import (
	"sync"
	"testing"
)

func TestInvalidStateCannotPartiallyCommit(t *testing.T) {
	if ApplyJSON([]byte(`{"current-profile-name":"PUBLIC_ORIGINAL","only-statistics-proxy":false}`)) != nil {
		t.Fatal("公开fixture初始化失败")
	}
	if ApplyJSON([]byte(`{"current-profile-name":"PUBLIC_CHANGED","only-statistics-proxy":"INVALID"}`)) == nil {
		t.Fatal("错误类型未拒绝")
	}
	if Snapshot().CurrentProfileName != "PUBLIC_ORIGINAL" {
		t.Fatal("错误输入部分提交了状态")
	}
}

func TestSnapshotHasNoMutableAliases(t *testing.T) {
	if ApplyJSON([]byte(`{"vpn-props":{"accessControl":{"enable":true,"acceptList":["PUBLIC_ACCEPT"],"rejectList":["PUBLIC_REJECT"]}},"bypass-domain":["fixture.invalid"]}`)) != nil {
		t.Fatal("公开fixture初始化失败")
	}
	x := Snapshot()
	x.VpnProps.AccessControl.Enable = false
	x.VpnProps.AccessControl.AcceptList[0] = "PUBLIC_CHANGED"
	x.VpnProps.AccessControl.RejectList[0] = "PUBLIC_CHANGED"
	x.BypassDomain[0] = "changed.invalid"
	y := Snapshot()
	if !y.VpnProps.AccessControl.Enable || y.VpnProps.AccessControl.AcceptList[0] != "PUBLIC_ACCEPT" ||
		y.VpnProps.AccessControl.RejectList[0] != "PUBLIC_REJECT" || y.BypassDomain[0] != "fixture.invalid" {
		t.Fatal("快照含可变别名")
	}
}

func TestValidPartialStateUpdatePreservesFields(t *testing.T) {
	if ApplyJSON([]byte(`{"current-profile-name":"PUBLIC_PROFILE","only-statistics-proxy":true,"bypass-domain":[],"vpn-props":{"accessControl":null}}`)) != nil ||
		ApplyJSON([]byte(`{"unknown-fixture":true,"vpn-props":{"allowBypass":true}}`)) != nil {
		t.Fatal("有效部分更新兼容性变化")
	}
	x := Snapshot()
	if x.CurrentProfileName != "PUBLIC_PROFILE" || !x.OnlyStatisticsProxy || !x.VpnProps.AllowBypass ||
		x.BypassDomain == nil || x.VpnProps.AccessControl != nil {
		t.Fatal("部分更新或nil/空列表语义变化")
	}
}

func TestMergeJSONUsesExplicitSnapshotWithoutGlobalCommit(t *testing.T) {
	Replace(State{
		CurrentProfileName: "PUBLIC_GLOBAL",
		BypassDomain:       []string{"global.invalid"},
	})
	base := State{
		CurrentProfileName: "PUBLIC_BASE",
		BypassDomain:       []string{"base.invalid"},
	}
	merged, err := MergeJSON(base, []byte(`{"vpn-props":{"allowBypass":true}}`))
	if err != nil {
		t.Fatalf("显式快照合并失败: %v", err)
	}
	if merged.CurrentProfileName != "PUBLIC_BASE" || !merged.VpnProps.AllowBypass || merged.BypassDomain[0] != "base.invalid" {
		t.Fatalf("显式快照合并结果错误: %+v", merged)
	}
	merged.BypassDomain[0] = "changed.invalid"
	if base.BypassDomain[0] != "base.invalid" || Snapshot().CurrentProfileName != "PUBLIC_GLOBAL" {
		t.Fatal("纯合并泄露别名或提交了全局状态")
	}
}

func TestReplaceCopiesMutableState(t *testing.T) {
	value := State{
		BypassDomain: []string{"replace.invalid"},
		VpnProps: AndroidVpnRawOptions{AccessControl: &AccessControl{
			Enable:     true,
			AcceptList: []string{"PUBLIC_ACCEPT"},
		}},
	}
	Replace(value)
	value.BypassDomain[0] = "changed.invalid"
	value.VpnProps.AccessControl.AcceptList[0] = "PUBLIC_CHANGED"
	actual := Snapshot()
	if actual.BypassDomain[0] != "replace.invalid" || actual.VpnProps.AccessControl.AcceptList[0] != "PUBLIC_ACCEPT" {
		t.Fatal("Replace保留了调用方可变别名")
	}
}

func TestConcurrentStateUpdatesAndReaders(t *testing.T) {
	var work sync.WaitGroup
	for i := 0; i < 8; i++ {
		work.Add(1)
		go func() {
			defer work.Done()
			for j := 0; j < 100; j++ {
				if ApplyJSON([]byte(`{"current-profile-name":"PUBLIC_CONCURRENT","only-statistics-proxy":true,"bypass-domain":["fixture.invalid"]}`)) != nil {
					t.Error("并发公开fixture提交失败")
				}
				x := Snapshot()
				if x.BypassDomain != nil {
					x.BypassDomain[0] = "LOCAL_COPY"
				}
			}
		}()
	}
	work.Wait()
}
