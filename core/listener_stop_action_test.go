//go:build !cgo

package main

import (
	"encoding/json"
	"errors"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
)

type stopActionConfig struct{ name string }

func (c stopActionConfig) Name() string { return c.name }
func (c stopActionConfig) Equal(other C.InboundConfig) bool {
	value, ok := other.(stopActionConfig)
	return ok && value == c
}

// 仅登记公开替身；Listen不创建socket、TUN或系统代理。
type stopActionInbound struct {
	name       string
	fail       bool
	panicClose bool
	closeCalls int
}

func (f *stopActionInbound) Name() string            { return f.name }
func (f *stopActionInbound) Address() string         { return "公开替身地址" }
func (f *stopActionInbound) RawAddress() string      { return "公开替身地址" }
func (f *stopActionInbound) Config() C.InboundConfig { return stopActionConfig{f.name} }
func (f *stopActionInbound) Listen(C.Tunnel) error   { return nil }
func (f *stopActionInbound) Close() error {
	f.closeCalls++
	if f.panicClose {
		panic("公开关闭恐慌")
	}
	if f.fail {
		return errors.New("公开关闭失败")
	}
	return nil
}

func callStopListenerAction(t *testing.T) bool {
	t.Helper()
	var reply ActionResult
	replies := 0
	result := ActionResult{Id: "public-stop", Method: stopListenerMethod, ownedSend: func(payload []byte) {
		replies++
		if err := json.Unmarshal(payload, &reply); err != nil {
			t.Fatal("公开停止动作结果解析失败")
		}
	}}
	handleAction(&Action{Id: "public-stop", Method: stopListenerMethod}, result)
	value, ok := reply.Data.(bool)
	// 保持现有bool ABI：动作已执行的code为0，关闭未确认以data=false报告。
	if replies != 1 || reply.Code != 0 || !ok || reply.Id != "public-stop" || reply.Method != stopListenerMethod {
		t.Fatal("停止动作未返回唯一且关联的bool结果")
	}
	return value
}

func TestStopListenerHandlerAndActionConfirmRegisteredCloseAndRetry(t *testing.T) {
	for _, entry := range []struct {
		name string
		stop func(*testing.T) bool
	}{
		{"handler", func(*testing.T) bool { return handleStopListener() }},
		{"action", callStopListenerAction},
	} {
		for _, mode := range []string{"成功", "错误", "恐慌", "多对象"} {
			t.Run(entry.name+"/"+mode, func(t *testing.T) {
				previousOwned := ownedListenerMode.Swap(false)
				runLock.Lock()
				previousRunning := isRunning
				isRunning = true
				runLock.Unlock()
				bad := &stopActionInbound{name: "公开主对象", fail: mode == "错误" || mode == "多对象", panicClose: mode == "恐慌"}
				fixtures := []*stopActionInbound{bad}
				registered := map[string]C.InboundListener{bad.name: bad}
				if mode == "多对象" {
					good := &stopActionInbound{name: "公开成功对象"}
					panicking := &stopActionInbound{name: "公开恐慌对象", panicClose: true}
					fixtures = append(fixtures, good, panicking)
					registered[good.name] = good
					registered[panicking.name] = panicking
					registered["公开同对象别名"] = bad
				}
				t.Cleanup(func() {
					for _, fixture := range fixtures {
						fixture.fail = false
						fixture.panicClose = false
					}
					if err := listener.StopListenerChecked(); err != nil {
						t.Error("公开监听夹具清理未确认")
					}
					listener.PatchInboundListeners(map[string]C.InboundListener{}, nil, true)
					runLock.Lock()
					isRunning = previousRunning
					runLock.Unlock()
					ownedListenerMode.Store(previousOwned)
				})
				listener.PatchInboundListeners(registered, nil, true)
				stop := func() (value bool) {
					defer func() {
						if recover() != nil {
							t.Error("关闭恐慌越过生产停止结果边界")
						}
					}()
					return entry.stop(t)
				}
				if got := stop(); got != (mode == "成功") {
					t.Errorf("关闭结果不符：模式=%s，结果=%t", mode, got)
				}
				if isRunning {
					t.Error("停止请求未关闭新监听准入")
				}
				for _, fixture := range fixtures {
					if fixture.closeCalls != 1 {
						t.Errorf("单轮未对登记对象恰好关闭一次：%s，次数=%d", fixture.name, fixture.closeCalls)
					}
				}
				// 准入已关闭不代表资源已关闭；失败必须由同一对象的显式重试完成。
				for _, fixture := range fixtures {
					fixture.fail = false
					fixture.panicClose = false
				}
				if !stop() {
					t.Error("显式重试成功关闭未被确认")
				}
				for index, fixture := range fixtures {
					want := 2
					if mode == "成功" || (mode == "多对象" && index == 1) {
						want = 1
					}
					if fixture.closeCalls != want {
						t.Errorf("失败对象未保留或成功对象被重复关闭：%s，次数=%d，期望=%d", fixture.name, fixture.closeCalls, want)
					}
				}
			})
		}
	}
}
