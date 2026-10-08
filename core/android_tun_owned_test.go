package main

import (
	"core/androidstartup"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
)

type ownedBridgeResource struct {
	closes int
	fail   bool
}

func (r *ownedBridgeResource) Close() error {
	r.closes++
	if r.fail {
		return errors.New("公开关闭失败")
	}
	return nil
}
func bridgeFixture(t *testing.T) (*androidOwnedTunBridge, androidstartup.TunOwnership) {
	c, _ := configuredReservationFixture(t)
	return &androidOwnedTunBridge{configLock: &sync.Mutex{}, coordinator: c, state: &androidstartup.State{}}, androidstartup.TunOwnership{Epoch: c.epoch, ConfigRevision: c.lastApplied, Generation: 1}
}
func bridgeStart(b *androidOwnedTunBridge, owner androidstartup.TunOwnership, r *ownedBridgeResource) androidOwnedTunResult {
	return b.start(owner, 7, nil, nil, func(*androidTunReservation) androidTunOpen {
		return func(*androidstartup.OnceLease) (androidstartup.Resource, error) { return r, nil }
	})
}
func TestAndroidOwnedTunBridgeStartAndMatchedStop(t *testing.T) {
	b, o := bridgeFixture(t)
	r := &ownedBridgeResource{}
	s := bridgeStart(b, o, r)
	if !s.Started || !s.Running || !s.HasResource || s.Resource != o || s.Blocked || s.Outcome != "completed" || b.coordinator.tunReservation == nil {
		t.Fatalf("启动不完整: %+v", s)
	}
	old := o
	old.Generation++
	rejected := b.stop(old)
	if rejected.Stopped || !rejected.Running || rejected.Resource != o || r.closes != 0 || rejected.Outcome != "rejected" {
		t.Fatalf("旧代停止污染当前资源: %+v", rejected)
	}
	done := b.stop(o)
	if !done.Stopped || done.Running || done.HasResource || r.closes != 1 || b.coordinator.tunReservation != nil {
		t.Fatalf("匹配停止没有收口: %+v", done)
	}
}
func TestAndroidOwnedTunBridgeRejectKeepsOldResource(t *testing.T) {
	b, o := bridgeFixture(t)
	r := &ownedBridgeResource{}
	bridgeStart(b, o, r)
	old := o
	old.ConfigRevision++
	released, closed, prepared := 0, 0, 0
	result := b.start(old, 8, func() { released++ }, func() error { closed++; return nil }, func(*androidTunReservation) androidTunOpen { prepared++; return nil })
	if result.Outcome != "rejected" || !result.Running || !result.HasResource || result.Resource != o || r.closes != 0 || released != 1 || closed != 1 || prepared != 0 {
		t.Fatalf("拒绝新输入误停旧连接: %+v", result)
	}
}
func TestAndroidOwnedTunBridgeReservationCoversConstruction(t *testing.T) {
	b, o := bridgeFixture(t)
	entered, resume := make(chan struct{}), make(chan struct{})
	done := make(chan androidOwnedTunResult, 1)
	go func() {
		done <- b.start(o, 7, nil, nil, func(*androidTunReservation) androidTunOpen {
			return func(*androidstartup.OnceLease) (androidstartup.Resource, error) {
				close(entered)
				<-resume
				return &ownedBridgeResource{}, nil
			}
		})
	}()
	// RED占位实现不会进入构造；不通过永久等待制造红结果。
	select {
	case result := <-done:
		t.Fatalf("未进入真实构造: %+v", result)
	case <-entered:
	}
	b.configLock.Lock()
	result := b.coordinator.commitLocked(o.Epoch, o.ConfigRevision, fixtureMutation(t, androidConfigKindUpdate, `{}`))
	b.configLock.Unlock()
	close(resume)
	start := <-done
	if result.ErrorCode != androidConfigErrorTunReserved || !start.Started {
		t.Fatalf("构造期间配置未被预留: %+v %+v", result, start)
	}
}
func TestAndroidOwnedTunBridgeUnknownCleanupBlocksConfig(t *testing.T) {
	b, o := bridgeFixture(t)
	o.Generation = 0
	result := b.start(o, 7, nil, func() error { return errors.New("公开输入失败") }, func(*androidTunReservation) androidTunOpen { t.Fatal("非法身份进入构造"); return nil })
	if result.Outcome != "unknown" || !result.Blocked || !result.CleanupUnconfirmed || !b.coordinator.blocked {
		t.Fatalf("清理未知丢失: %+v", result)
	}
}
func TestAndroidOwnedTunBridgeNonVpnZeroFd(t *testing.T) {
	b, o := bridgeFixture(t)
	b.coordinator.options.Enable = false
	result := b.start(o, 0, nil, nil, func(*androidTunReservation) androidTunOpen {
		return func(*androidstartup.OnceLease) (androidstartup.Resource, error) {
			t.Fatal("fd0不应构造")
			return nil, nil
		}
	})
	if !result.Started || !result.Running || !result.HasResource || result.RetainsResource || result.RetainsLease {
		t.Fatalf("fd0模式失败: %+v", result)
	}
	if !b.stop(o).Stopped {
		t.Fatal("fd0停止失败")
	}
}

func TestAndroidOwnedTunBridgeStopUnknownRetainsReservation(t *testing.T) {
	b, o := bridgeFixture(t)
	r := &ownedBridgeResource{fail: true}
	bridgeStart(b, o, r)
	result := b.stop(o)
	if result.Stopped || !result.Running || !result.Blocked || !result.CleanupUnconfirmed || result.Resource != o || b.coordinator.tunReservation == nil {
		t.Fatalf("停止未知丢失归属: %+v", result)
	}
}

func TestAndroidOwnedTunBridgePreparePanicCannotEscapeOrStartFdZero(t *testing.T) {
	b, o := bridgeFixture(t)
	b.coordinator.options.Enable = false
	result := b.start(o, 0, nil, nil, func(*androidTunReservation) androidTunOpen { panic("公开准备失败") })
	if result.Started || result.Running || !result.Blocked || result.Outcome != "unknown" {
		t.Fatalf("准备异常冒充成功: %+v", result)
	}
	if !b.configLock.TryLock() {
		t.Fatal("准备异常泄露配置锁")
	}
	b.configLock.Unlock()
}

func TestAndroidOwnedTunBridgeModeMismatchClosesInput(t *testing.T) {
	b, o := bridgeFixture(t)
	b.coordinator.options.Enable = false
	closed, released := 0, 0
	result := b.start(o, 7, func() { released++ }, func() error { closed++; return nil }, func(*androidTunReservation) androidTunOpen { t.Fatal("模式错误进入准备"); return nil })
	if result.Outcome != "rejected" || result.ErrorCode != "tunModeMismatch" || result.Blocked || closed != 1 || released != 1 || b.coordinator.tunReservation != nil {
		t.Fatalf("模式拒绝未收尾: %+v", result)
	}
}

func TestAndroidOwnedTunBridgeStopRequiresBothIdentities(t *testing.T) {
	t.Run("预留不匹配而State匹配", func(t *testing.T) {
		b, o := bridgeFixture(t)
		r := &ownedBridgeResource{}
		bridgeStart(b, o, r)
		b.coordinator.tunReservation.generation++
		result := b.stop(o)
		if result.Stopped || result.Outcome != "rejected" || !result.Running || result.Resource != o || r.closes != 0 || b.coordinator.tunReservation == nil {
			t.Fatalf("单侧匹配误停资源: %+v", result)
		}
	})
	t.Run("预留匹配而State不匹配", func(t *testing.T) {
		b, o := bridgeFixture(t)
		bridgeStart(b, o, &ownedBridgeResource{})
		other := o
		other.Generation++
		var state androidstartup.State
		r := &ownedBridgeResource{}
		state.StartOwnedWithInputCleanupReport(other, 7, true, nil, func(*androidstartup.OnceLease) (androidstartup.Resource, error) { return r, nil }, nil)
		b.state = &state
		result := b.stop(o)
		if result.Stopped || result.Outcome != "unknown" || !result.Blocked || !result.Running || result.Resource != other || r.closes != 0 || b.coordinator.tunReservation == nil {
			t.Fatalf("内部漂移丢失责任: %+v", result)
		}
	})
}

// 公开生产桥回执供Kotlin消费者直接验证，不执行真实FD或业务网络。
func TestAndroidOwnedTunBridgeWireReceipts(t *testing.T) {
	type wireCase struct {
		Receipt    string `json:"receipt"`
		Epoch      int64  `json:"epoch"`
		Revision   int64  `json:"revision"`
		Generation int64  `json:"generation"`
		Operation  string `json:"operation"`
		Vpn        bool   `json:"vpn"`
		Outcome    string `json:"outcome"`
	}
	var cases []wireCase
	add := func(r androidOwnedTunResult, vpn bool) {
		data, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		cases = append(cases, wireCase{string(data), r.Request.Epoch, r.Request.ConfigRevision, r.Request.Generation, r.Operation, vpn, r.Outcome})
	}
	b, o := bridgeFixture(t)
	add(bridgeStart(b, o, &ownedBridgeResource{}), true)
	old := o
	old.Generation++
	add(b.stop(old), true)
	stale := o
	stale.ConfigRevision++
	add(b.start(stale, 8, nil, nil, func(*androidTunReservation) androidTunOpen { return nil }), true)
	add(b.stop(o), true)
	b, o = bridgeFixture(t)
	b.coordinator.options.Enable = false
	add(b.start(o, 0, nil, nil, func(*androidTunReservation) androidTunOpen { return nil }), false)
	add(b.stop(o), false)
	b, o = bridgeFixture(t)
	bridgeStart(b, o, &ownedBridgeResource{fail: true})
	add(b.stop(o), true)
	b, o = bridgeFixture(t)
	add(b.start(o, 7, nil, nil, func(*androidTunReservation) androidTunOpen {
		return func(*androidstartup.OnceLease) (androidstartup.Resource, error) {
			return nil, errors.New("公开构造失败")
		}
	}), true)
	b, o = bridgeFixture(t)
	add(b.start(o, 7, nil, nil, func(*androidTunReservation) androidTunOpen { panic("公开准备失败") }), true)
	encoded, err := json.Marshal(cases)
	if err != nil {
		t.Fatal(err)
	}
	fmt.Println("PUBLIC_TUN_WIRE=" + string(encoded))
}
