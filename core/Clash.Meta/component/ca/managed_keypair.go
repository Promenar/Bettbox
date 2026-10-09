package ca

import (
	"errors"
	"path/filepath"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/tls"
)

var errCertificateClosePending = errors.New("证书监听器关闭尚未确认")

type certificateWatcher interface {
	Add(string) error
	Close() error
	Events() <-chan fsnotify.Event
	Errors() <-chan error
}

type nativeCertificateWatcher struct{ *fsnotify.Watcher }

func (w nativeCertificateWatcher) Events() <-chan fsnotify.Event { return w.Watcher.Events }
func (w nativeCertificateWatcher) Errors() <-chan error          { return w.Watcher.Errors }

// ManagedTLSKeyPairLoader 显式持有文件监听与更新任务；发布后的证书对象不再修改。
type ManagedTLSKeyPairLoader struct {
	mu                     sync.Mutex
	certificate            *tls.Certificate
	stopping               bool
	watcher                certificateWatcher
	stop, done, nativeDone chan struct{}
	closeOnce              sync.Once
	closeErr               error
	reload                 func() (*tls.Certificate, error)
}

// NewManagedTLSKeyPairLoader 的非 nil 返回值始终需要 Close，包括同时返回错误的情况。
func NewManagedTLSKeyPairLoader(certificate, privateKey string) (*ManagedTLSKeyPairLoader, error) {
	if certificate == "" && privateKey == "" {
		var err error
		certificate, privateKey, _, err = NewRandomTLSKeyPair(KeyPairTypeRSA)
		if err != nil {
			return nil, err
		}
	}
	cert, err := tls.X509KeyPair([]byte(certificate), []byte(privateKey))
	if err == nil {
		return newManagedKeyPair(&cert, nil, nil), nil
	}
	certificate, privateKey = C.Path.Resolve(certificate), C.Path.Resolve(privateKey)
	if !C.Path.IsSafePath(certificate) {
		return nil, C.Path.ErrNotSafePath(certificate)
	}
	if !C.Path.IsSafePath(privateKey) {
		return nil, C.Path.ErrNotSafePath(privateKey)
	}
	reload := func() (*tls.Certificate, error) {
		cert, err := tls.LoadX509KeyPair(certificate, privateKey)
		return &cert, err
	}
	initial, err := reload()
	if err != nil {
		return nil, err
	}
	native, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	return startManagedKeyPair(initial, nativeCertificateWatcher{native}, reload, []string{certificate, privateKey})
}

func newManagedKeyPair(initial *tls.Certificate, watcher certificateWatcher, reload func() (*tls.Certificate, error)) *ManagedTLSKeyPairLoader {
	return &ManagedTLSKeyPairLoader{certificate: initial, watcher: watcher, reload: reload, stop: make(chan struct{}), done: make(chan struct{}), nativeDone: make(chan struct{})}
}

func startManagedKeyPair(initial *tls.Certificate, watcher certificateWatcher, reload func() (*tls.Certificate, error), paths []string) (*ManagedTLSKeyPairLoader, error) {
	l := newManagedKeyPair(initial, watcher, reload)
	parents := make(map[string]bool)
	for _, path := range paths {
		dir := filepath.Dir(path)
		if parents[dir] {
			continue
		}
		if err := watcher.Add(dir); err != nil {
			close(l.done)
			if closeErr := l.Close(); closeErr != nil {
				return l, errors.Join(err, closeErr)
			}
			return nil, err
		}
		parents[dir] = true
	}
	go l.run(paths)
	return l, nil
}

func (l *ManagedTLSKeyPairLoader) Load() (*tls.Certificate, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stopping {
		return nil, errCertificateClosePending
	}
	return l.certificate, nil
}

func (l *ManagedTLSKeyPairLoader) run(paths []string) {
	defer close(l.done)
	var timer *time.Timer
	var tick <-chan time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	schedule := func() {
		if timer == nil {
			timer = time.NewTimer(100 * time.Millisecond)
		} else {
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(100 * time.Millisecond)
		}
		tick = timer.C
	}
	// 登记后的补读属于已交付所有权的更新任务，阻塞时 Close 可报告未知并保留责任。
	// 该补读覆盖初始读取到目录登记之间的变化，不在构造期间新增无界读取。
	schedule()
	for {
		select {
		case <-l.stop:
			return
		case event, ok := <-l.watcher.Events():
			if !ok {
				return
			}
			for _, path := range paths {
				if filepath.Clean(event.Name) == path && event.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Rename|fsnotify.Remove) != 0 {
					schedule()
					break
				}
			}
		case _, ok := <-l.watcher.Errors():
			if !ok {
				return
			}
			// 溢出等事件丢失后重新读取；无效更新不会替换最后一个有效证书。
			schedule()
		case <-tick:
			tick = nil
			l.mu.Lock()
			if l.stopping {
				l.mu.Unlock()
				return
			}
			// 更新在同锁下准入，随后同步执行；Close 等待整个事件循环结束。
			l.mu.Unlock()
			cert, err := l.reload()
			l.mu.Lock()
			if err == nil && !l.stopping {
				l.certificate = cert
			}
			l.mu.Unlock()
		}
	}
}

func (l *ManagedTLSKeyPairLoader) Close() error {
	l.closeOnce.Do(func() {
		l.mu.Lock()
		l.stopping = true
		close(l.stop)
		l.mu.Unlock()
		if l.watcher == nil {
			close(l.done)
			close(l.nativeDone)
			return
		}
		// 原生关闭也属于受管理任务，超时后保留句柄，允许调用方重新确认完成。
		go func() { l.closeErr = l.watcher.Close(); close(l.nativeDone) }()
	})
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	select {
	case <-l.nativeDone:
	case <-deadline.C:
		return errCertificateClosePending
	}
	select {
	case <-l.done:
		return l.closeErr
	case <-deadline.C:
		return errors.Join(l.closeErr, errCertificateClosePending)
	}
}
