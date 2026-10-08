package main

import (
	b "bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/batch"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	"os"
	"runtime"
	"runtime/debug"
	"sync"
	"time"
)

var (
	currentConfig    *config.Config
	currentRawConfig *config.RawConfig
	version          = 0
	isRunning        = false
	runLock          sync.Mutex
	mBatch, _        = batch.New[bool](context.Background(), batch.WithConcurrencyNum[bool](50))
)

type ExternalProviders []ExternalProvider

func (a ExternalProviders) Len() int           { return len(a) }
func (a ExternalProviders) Less(i, j int) bool { return a[i].Name < a[j].Name }
func (a ExternalProviders) Swap(i, j int)      { a[i], a[j] = a[j], a[i] }

func getExternalProvidersRaw() map[string]cp.Provider {
	eps := make(map[string]cp.Provider)
	for n, p := range tunnel.Providers() {
		eps[n] = p
	}
	for n, p := range tunnel.RuleProviders() {
		eps[n] = p
	}
	return eps
}

func toExternalProvider(p cp.Provider) (*ExternalProvider, error) {
	switch p.(type) {
	case *provider.ProxySetProvider:
		psp := p.(*provider.ProxySetProvider)
		return &ExternalProvider{
			Name:             psp.Name(),
			Type:             psp.Type().String(),
			VehicleType:      psp.VehicleType().String(),
			Count:            psp.Count(),
			UpdateAt:         psp.UpdatedAt(),
			Path:             psp.Vehicle().Path(),
			SubscriptionInfo: psp.GetSubscriptionInfo(),
			Proxies:          psp.Proxies(),
		}, nil
	case *provider.InlineProvider:
		ip := p.(*provider.InlineProvider)
		return &ExternalProvider{
			Name:             ip.Name(),
			Type:             ip.Type().String(),
			VehicleType:      ip.VehicleType().String(),
			Count:            ip.Count(),
			UpdateAt:         time.Now(),
			Path:             "",
			SubscriptionInfo: nil,
			Proxies:          ip.Proxies(),
		}, nil
	case *rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		return &ExternalProvider{
			Name:        rsp.Name(),
			Type:        rsp.Type().String(),
			VehicleType: rsp.VehicleType().String(),
			Count:       rsp.Count(),
			UpdateAt:    rsp.UpdatedAt(),
			Path:        rsp.Vehicle().Path(),
		}, nil
	default:
		return nil, errors.New("not external provider")
	}
}

func sideUpdateExternalProvider(p cp.Provider, bytes []byte) error {
	switch p.(type) {
	case *provider.ProxySetProvider:
		psp := p.(*provider.ProxySetProvider)
		_, _, err := psp.SideUpdate(bytes)
		if err == nil {
			return err
		}
		return nil
	case *provider.InlineProvider:
		return nil
	case rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		_, _, err := rsp.SideUpdate(bytes)
		if err == nil {
			return err
		}
		return nil
	default:
		return errors.New("not external provider")
	}
}

func updateListeners() error {
	// 专用进程不启用订阅中的普通监听器；默认平台入口保持原行为。
	if ownedListenerMode.Load() {
		return nil
	}
	if !isRunning {
		return nil
	}
	if currentConfig == nil {
		return nil
	}
	listeners := currentConfig.Listeners
	general := currentConfig.General
	if err := listener.PatchInboundListenersChecked(listeners, tunnel.Tunnel, true); err != nil {
		return err
	}
	listener.SetAllowLan(general.AllowLan)
	inbound.SetSkipAuthPrefixes(general.SkipAuthPrefixes)
	inbound.SetAllowedIPs(general.LanAllowedIPs)
	inbound.SetDisAllowedIPs(general.LanDisAllowedIPs)
	listener.SetBindAddress(general.BindAddress)
	listener.ReCreateHTTP(general.Port, tunnel.Tunnel)
	listener.ReCreateSocks(general.SocksPort, tunnel.Tunnel)
	listener.ReCreateRedir(general.RedirPort, tunnel.Tunnel)
	listener.ReCreateTProxy(general.TProxyPort, tunnel.Tunnel)
	listener.ReCreateMixed(general.MixedPort, tunnel.Tunnel)
	listener.ReCreateShadowSocks(general.ShadowSocksConfig, tunnel.Tunnel)
	listener.ReCreateVmess(general.VmessConfig, tunnel.Tunnel)
	listener.ReCreateTuic(general.TuicServer, tunnel.Tunnel)
	if !features.Android {
		listener.ReCreateTun(general.Tun, tunnel.Tunnel)
	}
	return nil
}

func stopListeners() {
	listener.StopListener()
}

func patchSelectGroup(mapping map[string]string) {
	for name, proxy := range tunnel.Proxies() {
		outbound, ok := proxy.(*adapter.Proxy)
		if !ok {
			continue
		}

		selector, ok := outbound.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			continue
		}

		selected, exist := mapping[name]
		if !exist {
			continue
		}

		selector.ForceSet(selected)
	}
}

func defaultSetupParams() *SetupParams {
	return &SetupParams{
		Config:      config.DefaultRawConfig(),
		TestURL:     "https://g.cn/generate_204",
		SelectedMap: map[string]string{},
	}
}

func readFile(path string) ([]byte, error) {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	return data, err
}

func updateConfig(params *UpdateParams) error {
	runLock.Lock()
	defer runLock.Unlock()
	if err := androidLegacyConfigWriteErrorLocked(); err != nil {
		return err
	}
	return updateConfigLocked(params)
}

// 调用者持有runLock；保留updateConfig既有更新顺序和行为。
func updateConfigLocked(params *UpdateParams) error {
	if currentConfig == nil {
		return errors.New("核心尚未配置")
	}
	general := currentConfig.General
	wasDebug := general.LogLevel == log.DEBUG
	if params.MixedPort != nil {
		general.MixedPort = *params.MixedPort
	}
	if params.Sniffing != nil {
		general.Sniffing = *params.Sniffing
		tunnel.SetSniffing(general.Sniffing)
	}
	if params.FindProcessMode != nil {
		general.FindProcessMode = *params.FindProcessMode
		tunnel.SetFindProcessMode(general.FindProcessMode)
	}
	if params.TCPConcurrent != nil {
		general.TCPConcurrent = *params.TCPConcurrent
		dialer.SetTcpConcurrent(general.TCPConcurrent)
	}
	if params.Interface != nil {
		general.Interface = *params.Interface
		dialer.DefaultInterface.Store(general.Interface)
	}
	if params.UnifiedDelay != nil {
		general.UnifiedDelay = *params.UnifiedDelay
		adapter.UnifiedDelay.Store(general.UnifiedDelay)
	}
	if params.Mode != nil {
		general.Mode = *params.Mode
		tunnel.SetMode(general.Mode)
	}
	if params.LogLevel != nil {
		general.LogLevel = *params.LogLevel
		log.SetLevel(general.LogLevel)
	}
	if params.IPv6 != nil {
		general.IPv6 = *params.IPv6
		resolver.DisableIPv6 = !general.IPv6
	}
	if params.ExternalController != nil {
		currentConfig.Controller.ExternalController = *params.ExternalController
	}

	isDebug := general.LogLevel == log.DEBUG
	needRecreateServer := params.ExternalController != nil ||
		(params.LogLevel != nil && isDebug != wasDebug)

	if needRecreateServer {
		route.ReCreateServer(&route.Config{
			Addr:           currentConfig.Controller.ExternalController,
			TLSAddr:        currentConfig.Controller.ExternalControllerTLS,
			UnixAddr:       currentConfig.Controller.ExternalControllerUnix,
			PipeAddr:       currentConfig.Controller.ExternalControllerPipe,
			Secret:         currentConfig.Controller.Secret,
			Certificate:    currentConfig.TLS.Certificate,
			PrivateKey:     currentConfig.TLS.PrivateKey,
			ClientAuthType: currentConfig.TLS.ClientAuthType,
			ClientAuthCert: currentConfig.TLS.ClientAuthCert,
			EchKey:         currentConfig.TLS.EchKey,
			DohServer:      currentConfig.Controller.ExternalDohServer,
			IsDebug:        isDebug,
			Cors: route.Cors{
				AllowOrigins:        currentConfig.Controller.Cors.AllowOrigins,
				AllowPrivateNetwork: currentConfig.Controller.Cors.AllowPrivateNetwork,
			},
		})
	}

	if params.Tun != nil {
		general.Tun.Enable = params.Tun.Enable
		general.Tun.AutoRoute = *params.Tun.AutoRoute
		general.Tun.Device = *params.Tun.Device
		general.Tun.RouteAddress = *params.Tun.RouteAddress
		if params.Tun.RouteExcludeAddress != nil {
			general.Tun.RouteExcludeAddress = *params.Tun.RouteExcludeAddress
		}
		if params.Tun.StrictRoute != nil {
			general.Tun.StrictRoute = *params.Tun.StrictRoute
		}
		general.Tun.DNSHijack = *params.Tun.DNSHijack
		general.Tun.Stack = *params.Tun.Stack
		general.Tun.DisableICMPForwarding = *params.Tun.DisableICMPForwarding
	}

	return updateListeners()
}

type preparedSetupConfig struct {
	params *SetupParams
	parsed *config.Config
}

func cloneSetupParams(params *SetupParams) (*SetupParams, error) {
	if params == nil || params.Config == nil {
		return nil, errors.New("配置参数无效")
	}
	data, err := json.Marshal(params)
	if err != nil {
		return nil, errors.New("配置参数无效")
	}
	var copied SetupParams
	if err := UnmarshalJson(data, &copied); err != nil || copied.Config == nil {
		return nil, errors.New("配置参数无效")
	}
	for index, group := range copied.Config.ProxyGroup {
		// JSON复制不能把原浮点数变成Number后改变既有截断语义。
		if elm, ok := params.Config.ProxyGroup[index]["tolerance"]; ok {
			switch v := elm.(type) {
			case json.Number:
				if i, err := v.Int64(); err == nil {
					group["tolerance"] = int(i)
				}
			case float64:
				group["tolerance"] = int(v)
			case float32:
				group["tolerance"] = int(v)
			case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
				group["tolerance"] = v
			}
		}
	}
	if copied.OverrideTestUrl {
		for _, group := range copied.Config.ProxyGroup {
			if group != nil {
				group["url"] = copied.TestURL
			}
		}
	}
	return &copied, nil
}

// 调用者持有runLock；解析存在自身临时状态与资源行为，并非纯校验。
func prepareSetupConfigLocked(params *SetupParams) (*preparedSetupConfig, error) {
	copied, err := cloneSetupParams(params)
	if err != nil {
		return nil, err
	}
	previousURL := constant.DefaultTestURL
	constant.DefaultTestURL = copied.TestURL
	defer func() { constant.DefaultTestURL = previousURL }()
	parsed, err := config.ParseRawConfig(copied.Config)
	if err != nil {
		return nil, err
	}
	return &preparedSetupConfig{params: copied, parsed: parsed}, nil
}

// 准备成功后才发布已复制的配置；保留现有成功应用顺序。
func commitSetupConfigLocked(prepared *preparedSetupConfig) error {
	currentConfig = prepared.parsed
	currentRawConfig = prepared.params.Config
	constant.DefaultTestURL = prepared.params.TestURL
	hub.ApplyConfig(currentConfig)
	patchSelectGroup(prepared.params.SelectedMap)
	if err := updateListeners(); err != nil {
		return err
	}
	runtime.GC()
	debug.FreeOSMemory()
	return nil
}

func setupConfig(params *SetupParams) error {
	runLock.Lock()
	defer runLock.Unlock()
	if err := androidLegacyConfigWriteErrorLocked(); err != nil {
		return err
	}
	return setupConfigLocked(params)
}

// 调用方持有runLock并已核验入口；owned driver直接使用prepare/commit原语。
func setupConfigLocked(params *SetupParams) error {
	prepared, err := prepareSetupConfigLocked(params)
	if err != nil {
		return err
	}
	return commitSetupConfigLocked(prepared)
}

func UnmarshalJson(data []byte, v any) error {
	decoder := json.NewDecoder(b.NewReader(data))
	decoder.UseNumber()
	err := decoder.Decode(v)
	return err
}
