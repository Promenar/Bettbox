//go:build ios && cgo && with_gvisor

package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"core/iosbridge"
	"core/state"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"path/filepath"
	"sync"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	MC "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

const iosMaxRequest = 1024 * 1024
const iosMaxResponse = 4 * 1024 * 1024

var iosRuntime iosbridge.Runtime
var iosRPC = iosbridge.NewSerialRPC()
var iosEvents = make(chan []byte, 64)
var iosReplies = struct {
	sync.Mutex
	next    int64
	pending map[int64]chan []byte
}{pending: make(map[int64]chan []byte)}
var iosStartTime time.Time

// iOS Action 保持现有 JSON 信封，结果通过本地有界通道回传，不依赖 Dart VM。
func (result ActionResult) send() {
	data, err := result.Json()
	if err != nil {
		data = iosFailure(result.Id, result.Method, "结果无法序列化")
	}
	if len(data) > iosMaxResponse {
		data = iosFailure(result.Id, result.Method, "结果超过大小上限")
	}
	iosReplies.Lock()
	reply := iosReplies.pending[result.Port]
	iosReplies.Unlock()
	if reply != nil {
		select {
		case reply <- data:
		default:
		}
	}
}

func sendMessage(message Message) {
	result := ActionResult{Method: messageMethod, Data: message}
	data, err := result.Json()
	if err != nil || len(data) > 64*1024 {
		return
	}
	select {
	case iosEvents <- data:
	default:
	}
}

func nextHandle(action *Action, result ActionResult) bool {
	switch action.Method {
	case getRunTimeMethod:
		value := ""
		if iosRuntime.Running() {
			value = fmt.Sprintf("%d", iosStartTime.UnixMilli())
		}
		result.success(value)
	case getCurrentProfileNameMethod:
		result.success(state.Snapshot().CurrentProfileName)
	default:
		result.error("iOS 不支持该内核方法")
	}
	return true
}

func iosFailure(id string, method Method, message string) []byte {
	data, _ := json.Marshal(ActionResult{Id: id, Method: method, Code: -1, Data: message})
	return data
}

func iosTimeout(milliseconds C.int) time.Duration {
	value := int(milliseconds)
	if value < 1 {
		value = 10000
	}
	if value > 30000 {
		value = 30000
	}
	return time.Duration(value) * time.Millisecond
}

func iosString(data *C.char, length C.int) (string, error) {
	if data == nil || length <= 0 || length > iosMaxRequest {
		return "", errors.New("请求大小或指针无效")
	}
	return string(unsafe.Slice((*byte)(unsafe.Pointer(data)), int(length))), nil
}

func iosInvoke(data string, timeout time.Duration) []byte {
	var action Action
	if err := json.Unmarshal([]byte(data), &action); err != nil {
		return iosFailure("", "", "Action JSON 无效")
	}
	if len(action.Id) > 256 {
		return iosFailure("", action.Method, "请求标识过长")
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	value, err := iosRPC.Execute(ctx, func() []byte { return iosExecute(action) })
	if err != nil {
		return iosFailure(action.Id, action.Method, err.Error())
	}
	return value
}

func iosExecute(action Action) (response []byte) {
	defer func() {
		if recover() != nil {
			response = iosFailure(action.Id, action.Method, "内核请求参数或状态无效")
		}
	}()
	iosReplies.Lock()
	iosReplies.next++
	port := iosReplies.next
	reply := make(chan []byte, 1)
	iosReplies.pending[port] = reply
	iosReplies.Unlock()
	defer func() { iosReplies.Lock(); delete(iosReplies.pending, port); iosReplies.Unlock() }()
	result := ActionResult{Id: action.Id, Method: action.Method, Port: port}
	switch action.Method {
	case crashMethod:
		result.error("iOS 禁止主动崩溃")
	case startListenerMethod:
		if err := iosStart(action.Data); err != nil {
			result.error(err.Error())
		} else {
			result.success(true)
		}
	case stopListenerMethod:
		err := iosRuntime.Stop()
		iosStartTime = time.Time{}
		if err != nil {
			result.error(err.Error())
		} else {
			result.success(true)
		}
	case shutdownMethod:
		if err := iosRuntime.Stop(); err != nil {
			result.error(err.Error())
			break
		}
		iosStartTime = time.Time{}
		handleStopLog()
		result.success(handleShutdown())
		currentConfig = nil
		currentRawConfig = nil
	case initClashMethod:
		var params InitParams
		text, ok := action.Data.(string)
		if !ok || json.Unmarshal([]byte(text), &params) != nil || !filepath.IsAbs(params.HomeDir) {
			result.error("初始化目录或参数无效")
			break
		}
		if isInit {
			result.error("核心已经初始化")
			break
		}
		handleAction(&action, result)
	case setupConfigMethod:
		if !isInit || iosRuntime.Running() {
			result.error("配置需要已初始化且停止的核心")
			break
		}
		text, ok := action.Data.(string)
		if !ok {
			result.error("配置必须是 JSON 字符串")
			break
		}
		params := defaultSetupParams()
		if UnmarshalJson([]byte(text), params) != nil || params.Config == nil {
			result.error("配置 JSON 无效")
			break
		}
		iosRestrictConfig(params.Config)
		if err := setupConfig(params); err != nil {
			result.error(err.Error())
		} else {
			result.success("")
		}
	case updateConfigMethod:
		// 仅允许在线不涉及设备或权限的参数，其余需停止后 setupConfig。
		text, ok := action.Data.(string)
		var params UpdateParams
		if !ok || json.Unmarshal([]byte(text), &params) != nil {
			result.error("更新参数无效")
			break
		}
		if currentConfig == nil {
			result.error("核心尚未配置")
			break
		}
		if params.Tun != nil || params.ExternalController != nil || params.Interface != nil || params.MixedPort != nil || params.AllowLan != nil || params.FindProcessMode != nil || params.IPv6 != nil {
			result.error("设备、监听及权限参数需要停止后重新配置")
			break
		}
		updateConfig(&params)
		result.success("")
	case asyncTestDelayMethod:
		if err := iosValidateAction(action); err != nil {
			result.error(err.Error())
			break
		}
		result.success(iosTestDelay(action.Data.(string)))
	default:
		if err := iosValidateAction(action); err != nil {
			result.error(err.Error())
			break
		}
		handleAction(&action, result)
	}
	// 异步 Action 在回复前占有唯一 RPC 执行令牌；前端超时不会增加后台任务。
	return <-reply
}

// iosTestDelay 不使用共享 batch 历史表，扩展测速结果随单次 Action 释放。
func iosTestDelay(text string) string {
	var params TestDelayParams
	_ = json.Unmarshal([]byte(text), &params)
	proxy := tunnel.Proxies()[params.ProxyName]
	if proxy == nil {
		for _, provider := range tunnel.Providers() {
			for _, candidate := range provider.Proxies() {
				if candidate.Name() == params.ProxyName {
					proxy = candidate
					break
				}
			}
			if proxy != nil {
				break
			}
		}
	}
	url := params.TestUrl
	if url == "" {
		url = MC.DefaultTestURL
	}
	delay := Delay{Name: params.ProxyName, Url: url, Value: -1}
	if proxy != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(params.Timeout)*time.Millisecond)
		defer cancel()
		expected, err := utils.NewUnsignedRanges[uint16]("")
		if err == nil {
			value, err := proxy.URLTest(ctx, url, expected)
			if err == nil && value != 0 {
				delay.Value = int32(value)
			}
		}
	}
	data, _ := json.Marshal(delay)
	return string(data)
}

func iosValidateAction(action Action) error {
	switch action.Method {
	case changeProxyMethod:
		text, ok := action.Data.(string)
		var params ChangeProxyParams
		if !ok || json.Unmarshal([]byte(text), &params) != nil || params.GroupName == nil || params.ProxyName == nil || *params.GroupName == "" || *params.ProxyName == "" {
			return errors.New("节点选择参数无效")
		}
	case asyncTestDelayMethod:
		text, ok := action.Data.(string)
		var params TestDelayParams
		if !ok || json.Unmarshal([]byte(text), &params) != nil || params.ProxyName == "" || params.Timeout < 1 || params.Timeout > 30000 {
			return errors.New("测速参数或超时范围无效")
		}
	case getCountryCodeMethod:
		text, ok := action.Data.(string)
		if !ok || net.ParseIP(text) == nil {
			return errors.New("IP 地址无效")
		}
	case updateGeoDataMethod:
		return errors.New("地理资源由容器应用管理")
	}
	return nil
}

func iosRestrictConfig(raw *config.RawConfig) {
	raw.Tun.Enable = false
	raw.Tun.AutoRoute, raw.Tun.AutoRedirect, raw.Tun.AutoDetectInterface = false, false, false
	raw.Tun.FileDescriptor = 0
	raw.Tun.Stack = MC.TunGvisor
	raw.Tun.GSO = false
	raw.Port, raw.SocksPort, raw.RedirPort, raw.TProxyPort, raw.MixedPort = 0, 0, 0, 0, 0
	raw.ShadowSocksConfig, raw.VmessConfig = "", ""
	raw.ExternalController, raw.ExternalControllerTLS, raw.ExternalControllerUnix, raw.ExternalControllerPipe = "", "", "", ""
	raw.ExternalUI, raw.ExternalUIURL, raw.ExternalDohServer = "", "", ""
	raw.AllowLan = false
	raw.Interface = ""
	raw.RoutingMark = 0
	raw.FindProcessMode = process.FindProcessOff
	raw.DNS.Listen = ""
	raw.Listeners = nil
	raw.Tunnels = nil
	raw.TuicServer.Enable = false
	raw.IPTables.Enable = false
	raw.NTP.Enable = false
	// 自动资源下载由容器应用管理，扩展只使用配置中声明的 provider。
	raw.GeoAutoUpdate = false
}

type iosStartOptions struct {
	MTU         uint32   `json:"mtu"`
	Capacity    int      `json:"capacity"`
	IPv4Address string   `json:"ipv4-address"`
	IPv6Address string   `json:"ipv6-address"`
	DNSHijack   []string `json:"dns-hijack"`
}

func iosStart(data any) error {
	if !isInit || currentConfig == nil {
		return errors.New("核心尚未初始化及配置")
	}
	text, ok := data.(string)
	if !ok {
		return errors.New("启动需要显式网络设置 JSON 字符串")
	}
	var params iosStartOptions
	if json.Unmarshal([]byte(text), &params) != nil {
		return errors.New("启动参数无效")
	}
	ipv4, err := netip.ParsePrefix(params.IPv4Address)
	if err != nil || !ipv4.Addr().Is4() {
		return errors.New("IPv4 地址无效")
	}
	options := currentConfig.General.Tun
	options.MTU = params.MTU
	options.Inet4Address = []netip.Prefix{ipv4}
	options.Inet6Address = nil
	if currentConfig.General.IPv6 && params.IPv6Address == "" {
		return errors.New("IPv6 已启用，启动需要 IPv6 地址")
	}
	if !currentConfig.General.IPv6 && params.IPv6Address != "" {
		return errors.New("IPv6 未启用，启动不能添加 IPv6 地址")
	}
	if params.IPv6Address != "" {
		ipv6, err := netip.ParsePrefix(params.IPv6Address)
		if err != nil || !ipv6.Addr().Is6() {
			return errors.New("IPv6 地址无效")
		}
		options.Inet6Address = []netip.Prefix{ipv6}
	}
	options.DNSHijack = params.DNSHijack
	if len(options.DNSHijack) == 0 {
		options.DNSHijack = []string{"any:53"}
	}
	if err := iosRuntime.Start(options, tunnel.Tunnel, params.Capacity); err != nil {
		return err
	}
	iosStartTime = time.Now()
	return nil
}

//export bettbox_core_action
func bettbox_core_action(data *C.char, length C.int, timeoutMs C.int) *C.char {
	text, err := iosString(data, length)
	if err != nil {
		return C.CString(string(iosFailure("", "", err.Error())))
	}
	return C.CString(string(iosInvoke(text, iosTimeout(timeoutMs))))
}

//export bettbox_core_start
func bettbox_core_start(data *C.char, length C.int, timeoutMs C.int) *C.char {
	text, err := iosString(data, length)
	if err != nil {
		return C.CString(string(iosFailure("", startListenerMethod, err.Error())))
	}
	request, _ := json.Marshal(Action{Method: startListenerMethod, Data: text})
	return C.CString(string(iosInvoke(string(request), iosTimeout(timeoutMs))))
}

//export bettbox_core_stop
func bettbox_core_stop(timeoutMs C.int) *C.char {
	return C.CString(string(iosInvoke(`{"method":"stopListener"}`, iosTimeout(timeoutMs))))
}

//export bettbox_core_status
func bettbox_core_status() C.int {
	if iosRuntime.Running() {
		return 1
	}
	return 0
}

//export bettbox_core_lifecycle
func bettbox_core_lifecycle() C.int { return C.int(iosRuntime.State()) }

//export bettbox_core_packet_push
func bettbox_core_packet_push(data unsafe.Pointer, length C.int) C.int {
	a := iosRuntime.Adapter()
	if a == nil {
		return -2
	}
	if data == nil || length <= 0 || uint32(length) > a.MTU() {
		return -1
	}
	err := a.PushInbound(unsafe.Slice((*byte)(data), int(length)))
	if errors.Is(err, iosbridge.ErrClosed) {
		return -2
	}
	if errors.Is(err, iosbridge.ErrQueueFull) {
		return -3
	}
	if err != nil {
		return -1
	}
	return 0
}

//export bettbox_core_packet_poll
func bettbox_core_packet_poll(data unsafe.Pointer, capacity C.int, version *C.int) C.int {
	a := iosRuntime.Adapter()
	if a == nil {
		return -2
	}
	if data == nil || version == nil || capacity < 0 || uint32(capacity) < a.MTU() {
		return -1
	}
	packet, err := a.PollOutbound()
	if err != nil {
		return -2
	}
	if len(packet.Data) == 0 {
		return 0
	}
	copy(unsafe.Slice((*byte)(data), int(capacity)), packet.Data)
	*version = C.int(packet.Version)
	return C.int(len(packet.Data))
}

//export bettbox_core_event_poll
func bettbox_core_event_poll() *C.char {
	select {
	case data := <-iosEvents:
		return C.CString(string(data))
	default:
		return C.CString("")
	}
}

//export bettbox_core_free
func bettbox_core_free(data *C.char) { C.free(unsafe.Pointer(data)) }
