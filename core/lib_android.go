//go:build android && cgo

package main

import "C"
import (
	"core/androidstartup"
	bridge "core/dart-bridge"
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"unsafe"
)

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer

	gate     *androidstartup.CallbackGate
	lease    *androidstartup.OnceLease
	shutdown androidstartup.Shutdown
}

func (t *TunHandler) Close() error {
	err := t.shutdown.Close(t.gate, t.lease, func() error {
		if t.listener != nil {
			return t.listener.Close()
		}
		return nil
	})
	if err == nil {
		tunHandler.CompareAndSwap(t, nil)
	}
	return err
}

func (t *TunHandler) handleProtect(fd int) bool {
	pin, ok := t.gate.Enter()
	if !ok {
		return false
	}
	defer pin.Done()
	return Protect(t.callback, fd)
}

func (t *TunHandler) handleResolveProcess(source, target net.Addr) string {
	pin, ok := t.gate.Enter()
	if !ok {
		return ""
	}
	defer pin.Done()
	var protocol int
	uid := -1
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	if version < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return ResolveProcess(t.callback, protocol, source.String(), target.String(), uid)
}

var (
	tunState   androidstartup.State
	errBlocked = errors.New("blocked")
	tunHandler atomic.Pointer[TunHandler]
)

var ownedTunBridge = androidOwnedTunBridge{configLock: &runLock, coordinator: &productionAndroidConfigCoordinator, state: &tunState}

// 回执只包含固定状态，不把输入FD、回调指针或原始异常传回客户端。
func ownedTunResultJSON(result androidOwnedTunResult) *C.char {
	encoded, err := json.Marshal(result)
	if err != nil {
		return nil
	}
	return C.CString(string(encoded))
}

func handleStartOwnedTun(owner androidstartup.TunOwnership, fd int, callback unsafe.Pointer) androidOwnedTunResult {
	release := func() {
		if callback != nil {
			releaseObject(callback)
		}
	}
	var fdLease *androidstartup.FDLease
	if fd > 0 {
		fdLease, _ = androidstartup.NewFDLease(fd, syscall.Close)
	}
	cleanup := func() error {
		err := fdLease.ReleaseUnadopted()
		if err != nil {
			gate := androidstartup.NewCallbackGate(4)
			gate.CloseAdmission()
			tunHandler.CompareAndSwap(nil, &TunHandler{gate: gate})
		}
		return err
	}
	return ownedTunBridge.start(owner, fd, release, cleanup, func(*androidTunReservation) androidTunOpen {
		// prepare在runLock内，仅复制值；返回的构造函数在锁外执行。
		if currentConfig == nil || fd > 0 && callback == nil {
			return nil
		}
		config := androidTunConfig{ready: true, device: currentConfig.General.Tun.Device, stack: currentConfig.General.Tun.Stack, disableICMPForwarding: currentConfig.General.Tun.DisableICMPForwarding, mtu: uint32(currentConfig.General.Tun.MTU), ipv6: currentConfig.General.IPv6}
		return func(lease *androidstartup.OnceLease) (androidstartup.Resource, error) {
			handler := &TunHandler{callback: callback, gate: androidstartup.NewCallbackGate(4), lease: lease}
			tunHandler.Store(handler)
			listener, err, cleanupErr := t.StartOwned(fd, config.device, config.stack, config.disableICMPForwarding, config.mtu, config.ipv6, fdLease.Adopt)
			handler.listener = listener
			if err == nil && listener == nil {
				err = errors.New("TUN构造未返回资源")
			}
			if cleanupErr != nil {
				handler.shutdown.SeedCleanupFailure(cleanupErr)
			}
			return handler, err
		}
	})
}

func init() {
	initTunHook()
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		handler := tunHandler.Load()
		if handler != nil {
			return androidstartup.ProtectSocket(conn, handler.handleProtect)
		}
		return nil
	}
}

func handleStopTun() bool {
	return tunState.Stop()
}

type androidTunConfig struct {
	ready                 bool
	device                string
	stack                 constant.TUNStack
	disableICMPForwarding bool
	mtu                   uint32
	ipv6                  bool
}

func handleStartTun(fd int, callback unsafe.Pointer) bool {
	release := func() {
		if callback != nil {
			releaseObject(callback)
		}
	}
	var fdLease *androidstartup.FDLease
	if fd > 0 {
		var err error
		fdLease, err = androidstartup.NewFDLease(fd, syscall.Close)
		if err != nil {
			return tunState.StartWithInputCleanup(fd, false, release, nil, func() error { return syscall.Close(fd) })
		}
	}
	// 快照只含值类型，不保留配置对象或可变别名；配置锁先于生命周期锁释放。
	config := androidstartup.Snapshot(&runLock, func() androidTunConfig {
		if currentConfig == nil {
			return androidTunConfig{}
		}
		return androidTunConfig{
			ready:                 true,
			device:                currentConfig.General.Tun.Device,
			stack:                 currentConfig.General.Tun.Stack,
			disableICMPForwarding: currentConfig.General.Tun.DisableICMPForwarding,
			mtu:                   uint32(currentConfig.General.Tun.MTU),
			ipv6:                  currentConfig.General.IPv6,
		}
	})
	return tunState.StartWithInputCleanup(fd, config.ready && (fd <= 0 || callback != nil), release, func(lease *androidstartup.OnceLease) (androidstartup.Resource, error) {
		handler := &TunHandler{callback: callback, gate: androidstartup.NewCallbackGate(4), lease: lease}
		// 构造栈期间也需要保护 socket；解析回调不读取尚未提交的 listener。
		tunHandler.Store(handler)
		listener, err, cleanupErr := t.StartOwned(fd, config.device, config.stack, config.disableICMPForwarding, config.mtu, config.ipv6, fdLease.Adopt)
		handler.listener = listener
		if err == nil && listener == nil {
			err = errors.New("TUN 构造未返回资源")
		}
		if cleanupErr != nil {
			handler.shutdown.SeedCleanupFailure(cleanupErr)
		}
		return handler, err
	}, func() error {
		err := fdLease.ReleaseUnadopted()
		if err != nil {
			// 未采纳的输入关闭失败时留下拒绝回调的哨兵，禁止放行新 socket。
			gate := androidstartup.NewCallbackGate(4)
			gate.CloseAdmission()
			tunHandler.CompareAndSwap(nil, &TunHandler{gate: gate})
		}
		return err
	})
}

func handleGetRunTime() string {
	runtime := tunState.Runtime()
	if runtime.IsZero() {
		return ""
	}
	return strconv.FormatInt(runtime.UnixMilli(), 10)
}

func initTunHook() {
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		handler := tunHandler.Load()
		if handler == nil {
			return "", process.ErrPlatformNotSupport
		}
		src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
		if src == nil || dst == nil {
			return "", process.ErrInvalidNetwork
		}
		return handler.handleResolveProcess(src, dst), nil
	}
}

func handleGetAndroidVpnOptions() string {
	runLock.Lock()
	defer runLock.Unlock()
	if currentConfig == nil {
		log.Warnln("[APP] handleGetAndroidVpnOptions called before setupConfig")
		return ""
	}
	options := androidVpnOptionsSnapshotLocked(currentConfig, state.Snapshot())
	data, err := json.Marshal(options)
	if err != nil {
		return ""
	}
	return string(data)
}

func handleUpdateDns(value string) {
	go func() {
		dns.UpdateSystemDNS(strings.Split(value, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
}

func handleGetCurrentProfileName() string {
	return state.Snapshot().CurrentProfileName
}

func nextHandle(action *Action, result ActionResult) bool {
	switch action.Method {
	case getAndroidVpnOptionsMethod:
		result.success(handleGetAndroidVpnOptions())
		return true
	case updateDnsMethod:
		data := action.Data.(string)
		handleUpdateDns(data)
		result.success(true)
		return true
	case getRunTimeMethod:
		result.success(handleGetRunTime())
		return true
	case getCurrentProfileNameMethod:
		result.success(handleGetCurrentProfileName())
		return true
	}
	return false
}

//export quickStart
func quickStart(initParamsChar *C.char, paramsChar *C.char, stateParamsChar *C.char, port C.longlong) {
	i := int64(port)
	paramsString := C.GoString(initParamsChar)
	bytes := []byte(C.GoString(paramsChar))
	stateParams := C.GoString(stateParamsChar)
	go func() {
		result := androidstartup.QuickStart(
			func() bool { return handleInitClash(paramsString) },
			func() error { return handleSetState(stateParams) },
			func() string { return handleSetupConfig(bytes) },
		)
		bridge.SendToPort(i, result)
	}()
}

//export startTUN
func startTUN(fd C.int, callback unsafe.Pointer) bool {
	return handleStartTun(int(fd), callback)
}

//export startTUNOwned
func startTUNOwned(epoch, revision, generation C.longlong, fd C.int, callback unsafe.Pointer) *C.char {
	return ownedTunResultJSON(handleStartOwnedTun(androidstartup.TunOwnership{Epoch: int64(epoch), ConfigRevision: int64(revision), Generation: int64(generation)}, int(fd), callback))
}

//export stopTUNOwned
func stopTUNOwned(epoch, revision, generation C.longlong) *C.char {
	return ownedTunResultJSON(ownedTunBridge.stop(androidstartup.TunOwnership{Epoch: int64(epoch), ConfigRevision: int64(revision), Generation: int64(generation)}))
}

//export getRunTime
func getRunTime() *C.char {
	return C.CString(handleGetRunTime())
}

//export stopTun
func stopTun() bool {
	return handleStopTun()
}

//export getCurrentProfileName
func getCurrentProfileName() *C.char {
	return C.CString(handleGetCurrentProfileName())
}

//export getAndroidVpnOptions
func getAndroidVpnOptions() *C.char {
	return C.CString(handleGetAndroidVpnOptions())
}

//export setState
func setState(s *C.char) {
	paramsString := C.GoString(s)
	handleSetState(paramsString)
}

//export updateDns
func updateDns(s *C.char) {
	dnsList := C.GoString(s)
	handleUpdateDns(dnsList)
}
