package listener_test

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

// 只计数真实文件监听后端，不把包含测试材料的完整栈写入日志。
func nativeCertificateWatchers() int {
	buf := make([]byte, 2<<20)
	n := runtime.Stack(buf, true)
	count := 0
	for _, stack := range bytes.Split(buf[:n], []byte("\n\n")) {
		if bytes.Contains(stack, []byte("github.com/fsnotify/fsnotify.")) && bytes.Contains(stack, []byte(".readEvents(")) {
			count++
		}
	}
	return count
}

type rejectedCertificateBind struct{}

func (rejectedCertificateBind) Listen(context.Context, string, string) (net.Listener, error) {
	return nil, errors.New("公开测试拒绝绑定")
}
func (rejectedCertificateBind) ListenPacket(context.Context, string, string) (net.PacketConn, error) {
	panic("TCP 证书回归不应创建 UDP")
}

func TestTCPProtocolFileCertificateLifecycle(t *testing.T) {
	oldHome := C.Path.HomeDir()
	root := t.TempDir()
	C.SetHomeDir(root)
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	for _, factory := range tcpLifecycleFactories()[:3] {
		for _, failure := range []string{"normal-close", "bind", "ech", "client-ca", "reality"} {
			t.Run(factory.name+"/"+failure, func(t *testing.T) {
				before := nativeCertificateWatchers()
				cfg, _ := publicTLSFixture(t)
				certPath, keyPath := filepath.Join(root, "public.crt"), filepath.Join(root, "public.key")
				if os.WriteFile(certPath, []byte(cfg.Certificate), 0600) != nil || os.WriteFile(keyPath, []byte(cfg.PrivateKey), 0600) != nil {
					t.Fatal("合成测试文件写入失败")
				}
				cfg.Certificate, cfg.PrivateKey = certPath, keyPath
				var capture C.InboundListenConfig = &publicListenCapture{}
				switch failure {
				case "bind":
					capture = rejectedCertificateBind{}
				case "ech":
					cfg.EchKey = "PUBLIC_INVALID_ECH"
				case "client-ca":
					cfg.ClientAuthType = "require-and-verify"
					cfg.ClientAuthCert = "PUBLIC_INVALID_CA"
				case "reality":
					cfg.RealityConfig.PrivateKey = "PUBLIC_INVALID_REALITY"
				}
				l, err := factory.create(cfg, capture, nil)
				if failure == "normal-close" {
					if err != nil {
						t.Fatal("实际文件证书构造失败")
					}
					if nativeCertificateWatchers() <= before {
						t.Fatal("未建立真实文件监听")
					}
					if l.Close() != nil {
						t.Fatal("实际监听关闭未确认")
					}
				} else if err == nil {
					_ = l.Close()
					t.Fatal("无效配置或绑定应拒绝")
				}
				deadline := time.Now().Add(time.Second)
				for nativeCertificateWatchers() > before && time.Now().Before(deadline) {
					time.Sleep(time.Millisecond)
				}
				runtime.KeepAlive(l)
				if nativeCertificateWatchers() > before {
					t.Fatal("返回后真实文件监听仍存活")
				}
			})
		}
	}
}
