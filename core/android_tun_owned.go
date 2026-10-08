package main

import (
	"core/androidstartup"
	"sync"
)

type androidTunOpen func(*androidstartup.OnceLease) (androidstartup.Resource, error)
type androidOwnedTunResult struct {
	Operation          string                      `json:"operation"`
	Request            androidstartup.TunOwnership `json:"request"`
	Outcome            string                      `json:"outcome"`
	Phase              string                      `json:"phase"`
	Started            bool                        `json:"started"`
	Stopped            bool                        `json:"stopped"`
	Running            bool                        `json:"running"`
	Blocked            bool                        `json:"blocked"`
	CleanupUnconfirmed bool                        `json:"cleanupUnconfirmed"`
	RetainsResource    bool                        `json:"retainsResource"`
	RetainsLease       bool                        `json:"retainsLease"`
	Resource           androidstartup.TunOwnership `json:"resource"`
	HasResource        bool                        `json:"hasResource"`
	ErrorCode          string                      `json:"errorCode"`
}

// 串行边界不持配置锁执行构造、Java回调或资源关闭。
type androidOwnedTunBridge struct {
	operation   sync.Mutex
	configLock  *sync.Mutex
	coordinator *androidConfigCoordinator
	state       *androidstartup.State
}

// 准备阶段异常同样不能越过C ABI；配置锁由调用方释放，输入仍走State收尾。
func prepareOwnedTunOpen(prepare func(*androidTunReservation) androidTunOpen, reservation *androidTunReservation) (open androidTunOpen, panicked bool) {
	defer func() {
		if recover() != nil {
			open = nil
			panicked = true
		}
	}()
	return prepare(reservation), false
}

func (b *androidOwnedTunBridge) start(owner androidstartup.TunOwnership, fd int, release func(), cleanup func() error, prepare func(*androidTunReservation) androidTunOpen) androidOwnedTunResult {
	b.operation.Lock()
	defer b.operation.Unlock()
	result := androidOwnedTunResult{Operation: "start", Request: owner, Outcome: "rejected", Phase: "notEntered"}
	var reservation *androidTunReservation
	var open androidTunOpen
	var preparePanicked bool
	code := ""
	b.configLock.Lock()
	if owner.Epoch <= 0 || owner.ConfigRevision <= 0 || owner.Generation <= 0 || fd < 0 {
		code = "invalidTunIdentity"
	} else {
		reservation, code = b.coordinator.reserveTunLocked(owner.Epoch, owner.ConfigRevision)
		if reservation != nil {
			reservation.generation = owner.Generation
			if (fd > 0) != reservation.vpnRequired {
				code = "tunModeMismatch"
				b.coordinator.tunReservation = nil
				reservation = nil
			} else {
				open, preparePanicked = prepareOwnedTunOpen(prepare, reservation)
				if preparePanicked {
					b.coordinator.blockTunLocked()
				}
			}
		}
	}
	b.configLock.Unlock()
	if reservation == nil {
		report := b.state.RejectInputWithCleanup(release, cleanup)
		result.Running = report.Running
		result.RetainsResource = report.RetainsResource
		result.RetainsLease = report.RetainsLease
		result.Resource = report.Ownership
		result.HasResource = report.HasOwnership
		result.ErrorCode = code
		b.configLock.Lock()
		if report.Blocked {
			b.coordinator.blockTunLocked()
			result.ErrorCode = report.Code
		}
		result.Blocked = b.coordinator.blocked || report.Blocked
		b.configLock.Unlock()
		result.CleanupUnconfirmed = !report.InputCleanupConfirmed || report.Blocked
		if result.Blocked || result.CleanupUnconfirmed {
			result.Outcome = "unknown"
		}
		return result
	}
	report := b.state.StartOwnedWithInputCleanupReport(owner, fd, !preparePanicked && (fd == 0 || open != nil), release, open, cleanup)
	result.Started = report.Started
	result.Running = report.Running
	result.Resource = report.Ownership
	result.HasResource = report.HasOwnership
	result.RetainsResource = report.RetainsResource
	result.RetainsLease = report.RetainsLease
	result.CleanupUnconfirmed = report.CleanupUnconfirmed
	result.ErrorCode = report.Code
	if report.Entered {
		result.Phase = "entered"
	}
	b.configLock.Lock()
	code = b.coordinator.finishTunStartLocked(reservation, report)
	result.Blocked = b.coordinator.blocked
	b.configLock.Unlock()
	if code != "" {
		result.ErrorCode = code
	}
	switch {
	case result.Blocked || report.CleanupUnconfirmed:
		result.Outcome = "unknown"
	case report.Started:
		result.Outcome = "completed"
		result.Phase = "completed"
	default:
		result.Outcome = "failed"
	}
	return result
}
func (b *androidOwnedTunBridge) stop(owner androidstartup.TunOwnership) androidOwnedTunResult {
	b.operation.Lock()
	defer b.operation.Unlock()
	result := androidOwnedTunResult{Operation: "stop", Request: owner, Outcome: "rejected", Phase: "notEntered", ErrorCode: "tunOwnershipMismatch"}
	b.configLock.Lock()
	reservation := b.coordinator.tunReservation
	matched := reservation != nil && reservation.epoch == owner.Epoch && reservation.revision == owner.ConfigRevision && reservation.generation == owner.Generation && owner.Generation > 0
	b.configLock.Unlock()
	requested := owner
	if !matched {
		requested = androidstartup.TunOwnership{}
	}
	report := b.state.StopOwnedReport(requested)
	result.Stopped = report.Stopped
	result.Running = report.Running
	result.RetainsResource = report.RetainsResource
	result.RetainsLease = report.RetainsLease
	result.Resource = report.Ownership
	result.HasResource = report.HasOwnership
	result.CleanupUnconfirmed = report.Blocked
	b.configLock.Lock()
	if matched {
		result.Phase = "entered"
		result.ErrorCode = b.coordinator.finishTunStopLocked(reservation, report.Stopped && report.Matched && !report.Blocked)
		if result.ErrorCode == "" {
			result.Outcome = "completed"
			result.Phase = "completed"
		}
	}
	result.Blocked = b.coordinator.blocked || report.Blocked
	b.configLock.Unlock()
	if result.Blocked {
		result.Outcome = "unknown"
	}
	return result
}
