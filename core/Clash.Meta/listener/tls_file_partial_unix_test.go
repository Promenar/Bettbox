//go:build darwin || linux

package listener_test

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	IN "github.com/metacubex/mihomo/listener/inbound"
)

// 使用临时 FIFO 阻塞实际文件读取，不替换生产 loader 或原生 watcher。
type blockedCertificateBind struct {
	t    *testing.T
	path string
}

func (b blockedCertificateBind) Listen(context.Context, string, string) (net.Listener, error) {
	if os.Remove(b.path) != nil || syscall.Mkfifo(b.path, 0600) != nil {
		b.t.Fatal("临时 FIFO 准备失败")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		buf := make([]byte, 2<<20)
		n := runtime.Stack(buf, true)
		for _, stack := range bytes.Split(buf[:n], []byte("\n\n")) {
			if bytes.Contains(stack, []byte("component/ca.(*ManagedTLSKeyPairLoader).run(")) && bytes.Contains(stack, []byte("os.OpenFile(")) {
				return nil, errors.New("公开绑定失败，实际文件更新已阻塞")
			}
		}
		time.Sleep(time.Millisecond)
	}
	b.t.Fatal("实际证书更新未进入阻塞读取")
	return nil, errors.New("公开绑定失败")
}
func (blockedCertificateBind) ListenPacket(context.Context, string, string) (net.PacketConn, error) {
	panic("证书回归不应创建 UDP")
}

func TestTCPProtocolFileCertificatePartialOwner(t *testing.T) {
	root := t.TempDir()
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(root)
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	for _, factory := range tcpLifecycleFactories()[:3] {
		for _, wrapper := range []bool{false, true} {
			name := factory.name + "/factory"
			if wrapper {
				name = factory.name + "/inbound"
			}
			t.Run(name, func(t *testing.T) {
				cfg, _ := publicTLSFixture(t)
				certPEM := cfg.Certificate
				dir, err := os.MkdirTemp(root, "partial-")
				if err != nil {
					t.Fatal("测试目录创建失败")
				}
				certPath, keyPath := filepath.Join(dir, "partial.crt"), filepath.Join(dir, "partial.key")
				if os.WriteFile(certPath, []byte(cfg.Certificate), 0600) != nil || os.WriteFile(keyPath, []byte(cfg.PrivateKey), 0600) != nil {
					t.Fatal("合成证书写入失败")
				}
				cfg.Certificate, cfg.PrivateKey = certPath, keyPath
				capture := blockedCertificateBind{t: t, path: certPath}
				unblock := func() bool {
					file, err := os.OpenFile(certPath, os.O_WRONLY|syscall.O_NONBLOCK, 0600)
					if err != nil {
						return false
					}
					_, writeErr := file.Write([]byte(certPEM))
					closeErr := file.Close()
					return writeErr == nil && closeErr == nil
				}
				// 即使用例失败，也尝试解除真实读取；仅针对测试临时文件。
				t.Cleanup(func() { _ = unblock() })
				before := nativeCertificateWatchers()
				var owned interface {
					Address() string
					Close() error
				}
				err = nil
				if !wrapper {
					value, buildErr := factory.create(cfg, capture, nil)
					err = buildErr
					if value != nil {
						owned, _ = value.(interface {
							Address() string
							Close() error
						})
					}
				} else {
					base := IN.BaseOption{NameStr: "PUBLIC_PARTIAL_OWNER", Listen: "127.0.0.1", ListenConfigForAPI: capture}
					var value C.InboundListener
					switch factory.name {
					case "HTTP":
						value, err = IN.NewHTTP(&IN.HTTPOption{BaseOption: base, Certificate: certPath, PrivateKey: keyPath})
					case "SOCKS":
						value, err = IN.NewSocks(&IN.SocksOption{BaseOption: base, Certificate: certPath, PrivateKey: keyPath})
					default:
						value, err = IN.NewMixed(&IN.MixedOption{BaseOption: base, Certificate: certPath, PrivateKey: keyPath})
					}
					if err != nil {
						t.Fatal("公开上层构造失败")
					}
					owned = value
					err = value.Listen(nil)
				}
				if owned == nil || err == nil || owned.Address() != "127.0.0.1:0" {
					_ = unblock()
					t.Fatal("失败构造遗失部分资源或地址不安全")
				}
				// 上层若丢弃部分对象，此处 Close 会错误返回成功。
				if owned.Close() == nil {
					_ = unblock()
					t.Fatal("真实证书读取阻塞时提前报告关闭")
				}
				if !unblock() {
					t.Fatal("实际文件读取解除失败")
				}
				if owned.Close() != nil {
					t.Fatal("迟到文件更新退出后不能确认关闭")
				}
				if nativeCertificateWatchers() > before {
					t.Fatal("确认关闭后真实文件监听仍存活")
				}
			})
		}
	}
}
