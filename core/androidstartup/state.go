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
	resource        Resource
	lease           *OnceLease
	runtime         time.Time
	inputCleanupErr error
}

// StopLocked 的内部逻辑只由同一把状态锁的持有者调用，不重入 Stop。
func (s *State) stopLocked() bool {
	if s.inputCleanupErr != nil {
		return false
	}
	if s.resource != nil && s.resource.Close() != nil {
		return false
	}
	s.runtime = time.Time{}
	s.resource = nil
	s.lease.Release()
	s.lease = nil
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
	s.mu.Lock()
	defer s.mu.Unlock()
	defer func() {
		if inputCleanup == nil {
			return
		}
		if err := inputCleanup(); err != nil {
			if started {
				s.stopLocked()
			}
			if s.inputCleanupErr == nil {
				s.inputCleanupErr = err
			}
			s.runtime = time.Time{}
			started = false
		}
	}()
	if !s.stopLocked() {
		if release != nil {
			release()
		}
		return false
	}
	if fd <= 0 {
		if release != nil {
			release()
		}
		if fd < 0 || !ready {
			return false
		}
		s.runtime = time.Now()
		return true
	}
	lease := NewOnceLease(release)
	if !ready {
		lease.Release()
		return false
	}
	resource, err := open(lease)
	if err != nil || resource == nil {
		if resource != nil {
			s.resource, s.lease = resource, lease
			// 部分启动清理失败时保留所有权，不能提前释放 JNI 引用。
			s.stopLocked()
		} else {
			lease.Release()
		}
		return false
	}
	s.resource, s.lease, s.runtime = resource, lease, time.Now()
	return true
}

func (s *State) Stop() bool         { s.mu.Lock(); defer s.mu.Unlock(); return s.stopLocked() }
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
