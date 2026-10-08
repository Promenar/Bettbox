package main

import (
	"core/androidstartup"
	"core/state"
)

const androidConfigErrorTunReserved = "tunConfigurationReserved"
const androidConfigErrorTunUnknown = "tunCleanupUnknown"
const androidConfigErrorTunReservation = "invalidTunReservation"

// 配置锁只保护预留发行与完成核验；调用方必须在锁外构造TUN和等待回调收尾。
// token不跨JNI传指针；原生owner接线时另行提供固定wire身份。
type androidTunReservation struct {
	epoch       int64
	revision    int64
	vpnRequired bool
	options     *state.AndroidVpnOptions
	settled     bool
	running     bool
}

func (c *androidConfigCoordinator) reserveTunLocked(epoch, revision int64) (*androidTunReservation, string) {
	if c.blocked {
		return nil, androidConfigErrorBlocked
	}
	if !c.driver.initializedLocked() {
		return nil, androidConfigErrorCoreNotInitialized
	}
	if epoch != c.epoch {
		return nil, androidConfigErrorStaleEpoch
	}
	if revision != c.lastApplied || revision <= 0 {
		return nil, androidConfigErrorStaleRevision
	}
	if !c.configured || c.options == nil {
		return nil, androidConfigErrorUnconfigured
	}
	if c.tunReservation != nil {
		return nil, androidConfigErrorTunReserved
	}
	r := &androidTunReservation{epoch: c.epoch, revision: c.lastApplied, vpnRequired: c.options.Enable, options: cloneAndroidVpnOptions(c.options)}
	c.tunReservation = r
	return r, ""
}

func (c *androidConfigCoordinator) validTunReservationLocked(r *androidTunReservation) bool {
	return r != nil && c.tunReservation == r && r.epoch == c.epoch && r.revision == c.lastApplied
}

func (c *androidConfigCoordinator) blockTunLocked() string {
	c.blocked = true
	if c.lastErrorCode == "" {
		c.lastErrorCode = androidConfigErrorTunUnknown
	}
	return androidConfigErrorTunUnknown
}

func (c *androidConfigCoordinator) finishTunStartLocked(r *androidTunReservation, report androidstartup.StartReport) string {
	// 无归属或重复回执不得释放当前责任，也不得污染后来合法预留。
	if r == nil || c.tunReservation != r || r.settled {
		return androidConfigErrorTunReservation
	}
	if c.blocked || !c.validTunReservationLocked(r) {
		return c.blockTunLocked()
	}
	r.settled = true
	if report.CleanupUnconfirmed {
		return c.blockTunLocked()
	}
	// 模式来自预留时的配置值，不能从调用方可读options重新推导。
	validMode := r.vpnRequired && report.Entered && report.RetainsResource && report.RetainsLease ||
		!r.vpnRequired && !report.Entered && !report.RetainsResource && !report.RetainsLease
	if report.Started && report.Running && report.Code == "" && validMode {
		r.running = true
		return ""
	}
	if !report.Started && !report.Running && !report.RetainsResource && !report.RetainsLease && report.Code != "" {
		c.tunReservation = nil
		return ""
	}
	// 矛盾或空报告不能证明收尾完成。
	return c.blockTunLocked()
}

func (c *androidConfigCoordinator) finishTunStopLocked(r *androidTunReservation, confirmed bool) string {
	if r == nil || c.tunReservation != r || !r.settled || !r.running {
		return androidConfigErrorTunReservation
	}
	if c.blocked || !c.validTunReservationLocked(r) || !confirmed {
		return c.blockTunLocked()
	}
	c.tunReservation = nil
	return ""
}
