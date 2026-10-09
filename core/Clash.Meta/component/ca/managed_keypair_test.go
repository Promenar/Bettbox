package ca

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/tls"
)

func publicManagedCertificate(t *testing.T) (string, string, *tls.Certificate) {
	t.Helper()
	cert, key, _, err := NewRandomTLSKeyPair(KeyPairTypeEd25519)
	if err != nil {
		t.Fatal("合成身份生成失败")
	}
	pair, err := tls.X509KeyPair([]byte(cert), []byte(key))
	if err != nil {
		t.Fatal("合成证书解析失败")
	}
	return cert, key, &pair
}

func TestManagedKeyPairRealFilesRotateAndClose(t *testing.T) {
	root := t.TempDir()
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(root)
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	certPath, keyPath := filepath.Join(root, "public.crt"), filepath.Join(root, "public.key")
	write := func(path, value string) {
		t.Helper()
		if os.WriteFile(path, []byte(value), 0600) != nil {
			t.Fatal("合成文件写入失败")
		}
	}
	cert, key, initial := publicManagedCertificate(t)
	write(certPath, cert)
	write(keyPath, key)
	l, err := NewManagedTLSKeyPairLoader(certPath, keyPath)
	if err != nil {
		t.Fatal("实际监听构造失败")
	}
	t.Cleanup(func() {
		if l.Close() != nil {
			t.Error("实际监听清理未确认")
		}
	})
	old, err := l.Load()
	if err != nil || !bytes.Equal(old.Certificate[0], initial.Certificate[0]) {
		t.Fatal("初始证书错误")
	}
	// 持有已发布旧证书并在轮换期间读取；race 检查保护调用方解锁后的读取。
	stopReader := make(chan struct{})
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		for {
			select {
			case <-stopReader:
				return
			default:
				_ = bytes.Equal(old.Certificate[0], initial.Certificate[0])
			}
		}
	}()
	t.Cleanup(func() { close(stopReader); <-readerDone })
	write(certPath, "PUBLIC_INVALID_CERTIFICATE")
	time.Sleep(250 * time.Millisecond)
	current, err := l.Load()
	if err != nil || current != old {
		t.Fatal("无效更新替换了有效证书")
	}
	cert2, key2, expected := publicManagedCertificate(t)
	write(keyPath, key2)
	write(certPath+".new", cert2)
	if os.Rename(certPath+".new", certPath) != nil {
		t.Fatal("合成证书原子替换失败")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		current, err = l.Load()
		if err == nil && bytes.Equal(current.Certificate[0], expected.Certificate[0]) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if err != nil || !bytes.Equal(current.Certificate[0], expected.Certificate[0]) {
		t.Fatal("实际文件替换未更新证书")
	}
	if !bytes.Equal(old.Certificate[0], initial.Certificate[0]) {
		t.Fatal("已发布旧证书被修改")
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Close() != nil {
				t.Error("并发关闭未确认")
			}
		}()
	}
	wg.Wait()
	if _, err := l.Load(); err == nil {
		t.Fatal("关闭后仍准入证书读取")
	}
}

type publicCertificateWatcher struct {
	events           chan fsnotify.Event
	errors           chan error
	addErr, closeErr error
	closed           atomic.Int32
	closeGate        <-chan struct{}
}

func newPublicCertificateWatcher() *publicCertificateWatcher {
	return &publicCertificateWatcher{events: make(chan fsnotify.Event, 8), errors: make(chan error)}
}
func (w *publicCertificateWatcher) Add(string) error              { return w.addErr }
func (w *publicCertificateWatcher) Events() <-chan fsnotify.Event { return w.events }
func (w *publicCertificateWatcher) Errors() <-chan error          { return w.errors }
func (w *publicCertificateWatcher) Close() error {
	w.closed.Add(1)
	if w.closeGate != nil {
		<-w.closeGate
	}
	close(w.events)
	close(w.errors)
	return w.closeErr
}

func TestManagedKeyPairCloseCancelsQueuedUpdate(t *testing.T) {
	_, _, cert := publicManagedCertificate(t)
	w := newPublicCertificateWatcher()
	var reloads atomic.Int32
	l, err := startManagedKeyPair(cert, w, func() (*tls.Certificate, error) { reloads.Add(1); return cert, nil }, []string{"public.crt"})
	if err != nil {
		t.Fatal("公开监听构造失败")
	}
	w.events <- fsnotify.Event{Name: "public.crt", Op: fsnotify.Write}
	if l.Close() != nil {
		t.Fatal("关闭未确认")
	}
	time.Sleep(150 * time.Millisecond)
	if reloads.Load() != 0 || w.closed.Load() != 1 {
		t.Fatal("关闭后排队更新仍启动或原生关闭次数错误")
	}
}

func TestManagedKeyPairCloseWaitsAdmittedUpdate(t *testing.T) {
	_, _, cert := publicManagedCertificate(t)
	_, _, replacement := publicManagedCertificate(t)
	w := newPublicCertificateWatcher()
	entered, release := make(chan struct{}), make(chan struct{})
	l, err := startManagedKeyPair(cert, w, func() (*tls.Certificate, error) {
		close(entered)
		<-release
		return replacement, nil
	}, []string{"public.crt"})
	if err != nil {
		t.Fatal("公开监听构造失败")
	}
	w.events <- fsnotify.Event{Name: "public.crt", Op: fsnotify.Create}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("更新未准入")
	}
	result := make(chan error, 1)
	go func() { result <- l.Close() }()
	select {
	case <-result:
		close(release)
		t.Fatal("已准入更新完成前报告关闭")
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	select {
	case err := <-result:
		if err != nil {
			t.Fatal("更新完成后关闭未确认")
		}
	case <-time.After(time.Second):
		t.Fatal("关闭未返回")
	}
	if l.certificate != cert {
		t.Fatal("关闭撤销后仍发布更新")
	}
}

func TestManagedKeyPairFailedAddRetainsCloseFailure(t *testing.T) {
	_, _, cert := publicManagedCertificate(t)
	w := newPublicCertificateWatcher()
	w.addErr = errors.New("公开 Add 失败")
	w.closeErr = errors.New("公开 Close 失败")
	l, err := startManagedKeyPair(cert, w, nil, []string{"public.crt"})
	if l == nil || !errors.Is(err, w.addErr) || !errors.Is(err, w.closeErr) {
		t.Fatal("失败构造遗失未确认资源或错误")
	}
	if !errors.Is(l.Close(), w.closeErr) || w.closed.Load() != 1 {
		t.Fatal("关闭错误未保留或重复调用原生关闭")
	}
	w = newPublicCertificateWatcher()
	w.addErr = errors.New("公开 Add 失败")
	l, err = startManagedKeyPair(cert, w, nil, []string{"public.crt"})
	if l != nil || !errors.Is(err, w.addErr) || w.closed.Load() != 1 {
		t.Fatal("Add 失败未清理资源")
	}
}

func TestManagedKeyPairCloseTimeoutCanConfirmLater(t *testing.T) {
	_, _, cert := publicManagedCertificate(t)
	w := newPublicCertificateWatcher()
	gate := make(chan struct{})
	w.closeGate = gate
	l, err := startManagedKeyPair(cert, w, func() (*tls.Certificate, error) { return cert, nil }, []string{"public.crt"})
	if err != nil {
		t.Fatal("公开监听构造失败")
	}
	if !errors.Is(l.Close(), errCertificateClosePending) {
		close(gate)
		t.Fatal("未知原生关闭提前报告成功")
	}
	close(gate)
	if l.Close() != nil || w.closed.Load() != 1 {
		t.Fatal("迟到完成不能确认或重复关闭")
	}
}

func TestManagedKeyPairInlineHasNoWatcher(t *testing.T) {
	cert, key, _ := publicManagedCertificate(t)
	l, err := NewManagedTLSKeyPairLoader(cert, key)
	if err != nil || l.watcher != nil {
		t.Fatal("内嵌证书不应创建文件监听")
	}
	if _, err = l.Load(); err != nil {
		t.Fatal("内嵌证书读取失败")
	}
	if l.Close() != nil || l.Close() != nil {
		t.Fatal("内嵌证书关闭应幂等")
	}
}

func TestManagedKeyPairConcurrentCloseRetainsError(t *testing.T) {
	_, _, cert := publicManagedCertificate(t)
	w := newPublicCertificateWatcher()
	w.closeErr = errors.New("公开原生关闭错误")
	l, err := startManagedKeyPair(cert, w, func() (*tls.Certificate, error) { return cert, nil }, []string{"public.crt"})
	if err != nil {
		t.Fatal("公开监听构造失败")
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if !errors.Is(l.Close(), w.closeErr) {
				t.Error("并发关闭遗失实际错误")
			}
		}()
	}
	wg.Wait()
	if w.closed.Load() != 1 {
		t.Fatal("并发关闭重复执行原生关闭")
	}
}

func TestManagedKeyPairReloadTimeoutCanConfirmLater(t *testing.T) {
	_, _, cert := publicManagedCertificate(t)
	w := newPublicCertificateWatcher()
	entered, release := make(chan struct{}), make(chan struct{})
	l, err := startManagedKeyPair(cert, w, func() (*tls.Certificate, error) {
		close(entered)
		<-release
		return cert, nil
	}, []string{"public.crt"})
	if err != nil {
		t.Fatal("公开监听构造失败")
	}
	w.events <- fsnotify.Event{Name: "public.crt", Op: fsnotify.Write}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("更新未准入")
	}
	if !errors.Is(l.Close(), errCertificateClosePending) {
		close(release)
		t.Fatal("更新未完成提前报告成功")
	}
	close(release)
	if l.Close() != nil || w.closed.Load() != 1 {
		t.Fatal("在途更新迟到完成未确认或重复关闭")
	}
}

func TestManagedKeyPairInitialRefreshOwnedBeforeRead(t *testing.T) {
	_, _, cert := publicManagedCertificate(t)
	w := newPublicCertificateWatcher()
	entered, release := make(chan struct{}), make(chan struct{})
	returned := make(chan *ManagedTLSKeyPairLoader, 1)
	go func() {
		l, err := startManagedKeyPair(cert, w, func() (*tls.Certificate, error) {
			close(entered)
			<-release
			return cert, nil
		}, []string{"public.crt"})
		if err != nil {
			t.Error("公开监听构造失败")
		}
		returned <- l
	}()
	var l *ManagedTLSKeyPairLoader
	select {
	case l = <-returned:
	case <-time.After(250 * time.Millisecond):
		close(release)
		l = <-returned
		_ = l.Close()
		t.Fatal("补读阻塞时资源所有权无法交付")
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		close(release)
		_ = l.Close()
		t.Fatal("登记后初始更新未启动")
	}
	if !errors.Is(l.Close(), errCertificateClosePending) {
		close(release)
		t.Fatal("初始更新阻塞却报告成功关闭")
	}
	close(release)
	if l.Close() != nil {
		t.Fatal("初始更新完成后不能确认关闭")
	}
}
