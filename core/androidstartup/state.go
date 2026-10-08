// Package androidstartup 提供不依赖 Android、JNI 或网络的启动提交与所有权逻辑。
package androidstartup

import (
	"errors"
	"sync"
	"syscall"
	"time"
)

type Resource interface{ Close() error }

// Snapshot 只保护 read 使用同一互斥量保护的源，返回值不得保留可变别名。
// 返回后已释放配置锁，调用方才可取得 Android 启停锁。
func Snapshot[T any](mu *sync.Mutex, read func() T) T {
	mu.Lock()
	defer mu.Unlock()
	return read()
}

type OnceLease struct {
	once    sync.Once
	release func()
}

func NewOnceLease(release func()) *OnceLease { return &OnceLease{release: release} }
func (l *OnceLease) Release() {
	if l != nil {
		l.once.Do(func() {
			if l.release != nil {
				l.release()
			}
		})
	}
}

type State struct {
	mu              sync.Mutex
	owner           *TunOwnership
	resource        Resource
	lease           *OnceLease
	pendingLeases   []*OnceLease
	runtime         time.Time
	inputCleanupErr error
	blockedCode     string
}

const (
	startCodeInvalidFD           = "invalidFD"
	startCodeNotReady            = "notReady"
	startCodeOpenFailed          = "openFailed"
	startCodeOpenPanic           = "openPanic"
	startCodeResourceCloseFailed = "resourceCloseFailed"
	startCodeResourceClosePanic  = "resourceClosePanic"
	startCodeInputCleanupFailed  = "inputCleanupFailed"
	startCodeInputCleanupPanic   = "inputCleanupPanic"
	startCodeReleasePanic        = "releasePanic"
	startCodeInternalPanic       = "internalPanic"
)

// StartReport 描述一次启动尝试结束后由 State 能直接证明的资源状态。
// RetainsLease 仅表示 State 仍持有 lease 指针，不证明外部 JNI 引用已释放。
type StartReport struct {
	Ownership          TunOwnership
	HasOwnership       bool
	Started            bool
	Entered            bool
	CleanupUnconfirmed bool
	RetainsResource    bool
	RetainsLease       bool
	Running            bool
	Code               string
}

// StartWithInputCleanupReport 在同一把状态锁内完成旧资源收口、新资源启动、
// 输入清理与最终报告。任一无法确认的清理结果都会保留可达责任并永久阻断新启动。
func (s *State) StartWithInputCleanupReport(
	fd int,
	ready bool,
	release func(),
	open func(*OnceLease) (Resource, error),
	inputCleanup func() error,
) (report StartReport) {
	return s.startWithOwnershipReport(nil, fd, ready, release, open, inputCleanup)
}

func (s *State) startWithOwnershipReport(owner *TunOwnership, fd int, ready bool, release func(), open func(*OnceLease) (Resource, error), inputCleanup func() error) (report StartReport) {
	s.mu.Lock()
	started := false
	entered := false
	attemptCode := ""
	var activeLease *OnceLease
	defer func() {
		if recover() != nil {
			if activeLease != nil {
				s.retainPendingLeaseLocked(activeLease)
			}
			s.markBlockedLocked(startCodeInternalPanic)
			started = false
		}

		cleanupErr, cleanupPanicked := callInputCleanup(inputCleanup)
		if cleanupErr != nil || cleanupPanicked {
			cleanupCode := startCodeInputCleanupFailed
			if cleanupPanicked {
				cleanupCode = startCodeInputCleanupPanic
				cleanupErr = errors.New("输入清理发生panic")
			}
			if s.inputCleanupErr == nil {
				s.inputCleanupErr = cleanupErr
			}
			s.markBlockedLocked(cleanupCode)
			if started {
				s.closeCurrentLocked()
			}
			started = false
		}

		code := attemptCode
		if s.blockedCode != "" {
			code = s.blockedCode
		}
		report = StartReport{
			Started:            started,
			Entered:            entered,
			CleanupUnconfirmed: s.blockedCode != "",
			RetainsResource:    s.resource != nil,
			RetainsLease:       s.lease != nil || len(s.pendingLeases) != 0,
			Running:            !s.runtime.IsZero(),
			Code:               code,
		}
		if s.owner != nil {
			report.Ownership = *s.owner
			report.HasOwnership = true
		}
		s.mu.Unlock()
	}()

	activeLease = NewOnceLease(release)
	if s.owner != nil || owner != nil && (!owner.valid() || s.resource != nil || s.lease != nil || !s.runtime.IsZero()) {
		attemptCode = "ownershipRejected"
		if releaseLease(activeLease) {
			s.retainPendingLeaseLocked(activeLease)
			s.markBlockedLocked(startCodeReleasePanic)
		}
		activeLease = nil
		return
	}
	if !s.stopLocked() {
		if releaseLease(activeLease) {
			s.retainPendingLeaseLocked(activeLease)
			s.markBlockedLocked(startCodeReleasePanic)
		}
		activeLease = nil
		return
	}
	if fd <= 0 {
		if fd == 0 && ready {
			s.setOwnerLocked(owner)
		}
		if releaseLease(activeLease) {
			s.retainPendingLeaseLocked(activeLease)
			s.markBlockedLocked(startCodeReleasePanic)
			activeLease = nil
			return
		}
		activeLease = nil
		if fd < 0 {
			attemptCode = startCodeInvalidFD
			return
		}
		if !ready {
			attemptCode = startCodeNotReady
			return
		}
		s.setOwnerLocked(owner)
		s.runtime = time.Now()
		started = true
		return
	}
	if !ready {
		attemptCode = startCodeNotReady
		if releaseLease(activeLease) {
			s.retainPendingLeaseLocked(activeLease)
			s.markBlockedLocked(startCodeReleasePanic)
		}
		activeLease = nil
		return
	}

	entered = true
	s.setOwnerLocked(owner)
	s.retainPendingLeaseLocked(activeLease)
	resource, err, panicked := callOpen(open, activeLease)
	if panicked {
		s.markBlockedLocked(startCodeOpenPanic)
		activeLease = nil
		return
	}
	s.removePendingLeaseLocked(activeLease)
	if err != nil || resource == nil {
		attemptCode = startCodeOpenFailed
		if resource != nil {
			s.resource, s.lease = resource, activeLease
			activeLease = nil
			s.closeCurrentLocked()
			return
		}
		if releaseLease(activeLease) {
			s.retainPendingLeaseLocked(activeLease)
			s.markBlockedLocked(startCodeReleasePanic)
		}
		activeLease = nil
		if s.blockedCode == "" {
			s.owner = nil
		}
		return
	}
	s.resource, s.lease, s.runtime = resource, activeLease, time.Now()
	activeLease = nil
	started = true
	return
}

func (s *State) markBlockedLocked(code string) {
	if s.blockedCode == "" {
		s.blockedCode = code
	}
}

func (s *State) retainPendingLeaseLocked(lease *OnceLease) {
	if lease == nil {
		return
	}
	for _, current := range s.pendingLeases {
		if current == lease {
			return
		}
	}
	s.pendingLeases = append(s.pendingLeases, lease)
}

func (s *State) removePendingLeaseLocked(lease *OnceLease) {
	for index, current := range s.pendingLeases {
		if current == lease {
			s.pendingLeases = append(s.pendingLeases[:index], s.pendingLeases[index+1:]...)
			return
		}
	}
}

func callOpen(open func(*OnceLease) (Resource, error), lease *OnceLease) (resource Resource, err error, panicked bool) {
	defer func() {
		if recover() != nil {
			resource = nil
			err = errors.New("资源构造发生panic")
			panicked = true
		}
	}()
	if open == nil {
		return nil, errors.New("资源构造入口为空"), false
	}
	resource, err = open(lease)
	return
}

func callInputCleanup(cleanup func() error) (err error, panicked bool) {
	if cleanup == nil {
		return nil, false
	}
	defer func() {
		if recover() != nil {
			err = errors.New("输入清理发生panic")
			panicked = true
		}
	}()
	err = cleanup()
	return
}

func closeResource(resource Resource) (err error, panicked bool) {
	defer func() {
		if recover() != nil {
			err = errors.New("资源关闭发生panic")
			panicked = true
		}
	}()
	err = resource.Close()
	return
}

func releaseLease(lease *OnceLease) (panicked bool) {
	defer func() {
		if recover() != nil {
			panicked = true
		}
	}()
	lease.Release()
	return false
}

// StopLocked 的内部逻辑只由同一把状态锁的持有者调用，不重入 Stop。
func (s *State) stopLocked() bool {
	if s.blockedCode != "" || s.inputCleanupErr != nil {
		return false
	}
	return s.closeCurrentLocked()
}

func (s *State) closeCurrentLocked() bool {
	if s.resource != nil {
		err, panicked := closeResource(s.resource)
		if err != nil || panicked {
			code := startCodeResourceCloseFailed
			if panicked {
				code = startCodeResourceClosePanic
			}
			s.markBlockedLocked(code)
			return false
		}
	}
	s.resource = nil
	s.runtime = time.Time{}
	if releaseLease(s.lease) {
		s.markBlockedLocked(startCodeReleasePanic)
		return false
	}
	s.lease = nil
	s.owner = nil
	return true
}

// Start 的 open 必须同步返回；成功资源和失败时的部分资源都移交状态机。
// fd0 是配置就绪的非 VPN 模式，不调用 open；负 FD 拒绝。
// 两者均不创建 lease，误移交的回调引用仍由 release 直接释放。
func (s *State) Start(fd int, ready bool, release func(), open func(*OnceLease) (Resource, error)) bool {
	return s.StartWithInputCleanup(fd, ready, release, open, nil)
}

// StartWithInputCleanup 在生命周期锁内收回尚未采纳的输入。
// 首次输入关闭错误永久保留，未知所有权下不能报告停止成功或启动新代。
func (s *State) StartWithInputCleanup(fd int, ready bool, release func(), open func(*OnceLease) (Resource, error), inputCleanup func() error) (started bool) {
	return s.StartWithInputCleanupReport(fd, ready, release, open, inputCleanup).Started
}

func (s *State) Stop() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.owner != nil {
		return false
	}
	return s.stopLocked()
}
func (s *State) Runtime() time.Time { s.mu.Lock(); defer s.mu.Unlock(); return s.runtime }

// FDLease 接管 Kotlin 脱离的 FD，仅关闭尚未被 NativeTun 采纳的输入。
type FDLease struct {
	mu       sync.Mutex
	fd       int
	adopted  bool
	closed   bool
	closeFD  func(int) error
	closeErr error
}

func NewFDLease(fd int, closeFD func(int) error) (*FDLease, error) {
	if fd <= 0 || closeFD == nil {
		return nil, errors.New("无效的移交 FD")
	}
	return &FDLease{fd: fd, closeFD: closeFD}, nil
}

// Adopt 必须在 NativeTun 已接管且 Listener 已登记 tunIf 后同步调用一次。
func (l *FDLease) Adopt() { l.mu.Lock(); defer l.mu.Unlock(); l.adopted = true }
func (l *FDLease) ReleaseUnadopted() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.adopted && !l.closed {
		l.closed = true
		l.closeErr = l.closeFD(l.fd)
	}
	return l.closeErr
}

// ProtectSocket 保留 Control 自身错误，并将保护拒绝传回 socket 创建方。
func ProtectSocket(conn syscall.RawConn, protect func(int) bool) error {
	protected := false
	err := conn.Control(func(fd uintptr) { protected = protect(int(fd)) })
	if err != nil {
		return err
	}
	if !protected {
		return errors.New("socket 保护失败")
	}
	return nil
}
