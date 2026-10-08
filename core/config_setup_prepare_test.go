//go:build !cgo

package main

import (
	"bytes"
	"encoding/json"
	"net/netip"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
)

func setupPrepareSentinels(t *testing.T) (*config.Config, *config.RawConfig, string) {
	t.Helper()
	runLock.Lock()
	oldConfig, oldRaw, oldURL := currentConfig, currentRawConfig, C.DefaultTestURL
	published := &config.Config{}
	publishedRaw := config.DefaultRawConfig()
	url := "https://public.invalid/confirmed"
	currentConfig, currentRawConfig, C.DefaultTestURL = published, publishedRaw, url
	runLock.Unlock()
	t.Cleanup(func() {
		runLock.Lock()
		currentConfig, currentRawConfig, C.DefaultTestURL = oldConfig, oldRaw, oldURL
		runLock.Unlock()
	})
	return published, publishedRaw, url
}

func failingSetupParams(tolerance interface{}, override bool) *SetupParams {
	raw := config.DefaultRawConfig()
	// 在proxy解析阶段失败，不能进入provider加载、规则资源或成功ApplyConfig。
	raw.Proxy = []map[string]any{{"name": "公开无效节点", "type": "PUBLIC_INVALID_PROXY_TYPE"}}
	raw.ProxyGroup = []map[string]any{{
		"name": "公开组", "type": "url-test", "proxies": []string{"DIRECT"},
		"tolerance": tolerance, "url": "https://public.invalid/original",
	}}
	raw.IPv6 = false
	raw.DNS.IPv6 = true
	raw.Tun.Enable = false
	raw.Tun.Inet6Address = []netip.Prefix{netip.MustParsePrefix("2001:db8::/64")}
	raw.Tun.Inet6RouteAddress = []netip.Prefix{netip.MustParsePrefix("2001:db8:1::/64")}
	return &SetupParams{
		Config: raw, SelectedMap: map[string]string{"公开组": "DIRECT"},
		TestURL: "https://public.invalid/rejected", OverrideTestUrl: override,
	}
}

func callSetupWithoutPanic(t *testing.T, params *SetupParams) (err error) {
	t.Helper()
	defer func() {
		if recover() != nil {
			t.Error("生产setupConfig不应让无效输入产生恐慌")
		}
	}()
	return setupConfig(params)
}

func assertSetupPublishedUnchanged(t *testing.T, published *config.Config, raw *config.RawConfig, url string) {
	t.Helper()
	if currentConfig != published {
		t.Error("失败setup替换了最后确认的currentConfig指针")
	}
	if currentRawConfig != raw {
		t.Error("失败setup替换了最后确认的currentRawConfig指针")
	}
	if C.DefaultTestURL != url {
		t.Error("失败setup留下了未确认请求的DefaultTestURL")
	}
}

func TestSetupConfigParseFailureRetainsPublishedConfigAndDefaultURL(t *testing.T) {
	for _, override := range []bool{false, true} {
		name := "保留组URL"
		if override {
			name = "覆盖组URL"
		}
		t.Run(name, func(t *testing.T) {
			published, raw, url := setupPrepareSentinels(t)
			if callSetupWithoutPanic(t, failingSetupParams(json.Number("31"), override)) == nil {
				t.Error("明确无效proxy类型未被生产setup拒绝")
			}
			assertSetupPublishedUnchanged(t, published, raw, url)
		})
	}
}

func TestSetupConfigParseFailureDoesNotMutateCallerRawConfig(t *testing.T) {
	for _, entry := range []struct {
		name      string
		tolerance interface{}
	}{
		{"jsonNumber", json.Number("31")},
		{"float64", float64(31.5)},
		{"float32", float32(31.5)},
	} {
		t.Run(entry.name, func(t *testing.T) {
			published, raw, url := setupPrepareSentinels(t)
			params := failingSetupParams(entry.tolerance, true)
			callerRaw := params.Config
			before, err := json.Marshal(params)
			if err != nil {
				t.Fatal("公开setup夹具序列化失败")
			}
			if callSetupWithoutPanic(t, params) == nil {
				t.Error("明确无效proxy类型未被生产setup拒绝")
			}
			after, err := json.Marshal(params)
			if err != nil || !bytes.Equal(before, after) || params.Config != callerRaw {
				t.Error("失败setup修改了调用方RawConfig、组URL或IPv6字段")
			}
			// JSON数值等价不能掩盖调用方tolerance实际类型被原地转换。
			if !reflect.DeepEqual(params.Config.ProxyGroup[0]["tolerance"], entry.tolerance) {
				t.Error("失败setup原地改变了调用方组tolerance值或类型")
			}
			assertSetupPublishedUnchanged(t, published, raw, url)
		})
	}
}

func TestSetupConfigNilInputReturnsFixedErrorWithoutChangingPublishedState(t *testing.T) {
	for _, entry := range []struct {
		name   string
		params *SetupParams
	}{
		{"nilParams", nil},
		{"nilConfig", &SetupParams{TestURL: "https://public.invalid/rejected"}},
	} {
		t.Run(entry.name, func(t *testing.T) {
			published, raw, url := setupPrepareSentinels(t)
			err := callSetupWithoutPanic(t, entry.params)
			if err == nil || err.Error() != "配置参数无效" {
				t.Error("nil输入未返回固定配置参数错误")
			}
			assertSetupPublishedUnchanged(t, published, raw, url)
		})
	}
}

func TestCloneSetupParamsPreservesToleranceConversionAndOwnsMutableData(t *testing.T) {
	for _, entry := range []struct {
		name  string
		input interface{}
		want  interface{}
	}{
		{"numberInteger", json.Number("31"), int(31)},
		{"numberFraction", json.Number("31.5"), json.Number("31.5")},
		{"numberOverflow", json.Number("9223372036854775808"), json.Number("9223372036854775808")},
		{"float64Fraction", float64(31.5), int(31)},
		{"float32Negative", float32(-31.5), int(-31)},
		{"integer", int(31), int(31)},
	} {
		t.Run(entry.name, func(t *testing.T) {
			published, raw, url := setupPrepareSentinels(t)
			params := failingSetupParams(entry.input, true)
			before, err := json.Marshal(params)
			if err != nil {
				t.Fatal("公开复制夹具序列化失败")
			}
			copied, err := cloneSetupParams(params)
			if err != nil || copied == nil || copied.Config == params.Config {
				t.Fatal("准备层没有独立复制调用方配置")
			}
			if !reflect.DeepEqual(copied.Config.ProxyGroup[0]["tolerance"], entry.want) {
				t.Error("复制后tolerance不符合既有类型转换语义")
			}
			if copied.Config.ProxyGroup[0]["url"] != params.TestURL {
				t.Error("组URL覆盖未作用于准备副本")
			}
			copied.Config.ProxyGroup[0]["url"] = "https://public.invalid/copied"
			copied.Config.ProxyGroup[0]["proxies"].([]interface{})[0] = "REJECT"
			copied.SelectedMap["公开组"] = "REJECT"
			copied.Config.Tun.Inet6Address[0] = netip.MustParsePrefix("2001:db8:2::/64")
			after, err := json.Marshal(params)
			if err != nil || !bytes.Equal(before, after) ||
				!reflect.DeepEqual(params.Config.ProxyGroup[0]["tolerance"], entry.input) {
				t.Error("准备副本仍共享调用方map、slice或tolerance数据")
			}
			assertSetupPublishedUnchanged(t, published, raw, url)
		})
	}
}
