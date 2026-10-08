package listener_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/auth"
	LC "github.com/metacubex/mihomo/listener/config"
	HTTP "github.com/metacubex/mihomo/listener/http"
	"github.com/metacubex/mihomo/listener/mixed"
	"github.com/metacubex/mihomo/listener/socks"
)

type publicListenCapture struct {
	listener net.Listener
	calls    int
}

func (c *publicListenCapture) Listen(_ context.Context, network, address string) (net.Listener, error) {
	c.calls++
	l, err := net.Listen(network, address)
	c.listener = l
	return l, err
}
func (*publicListenCapture) ListenPacket(context.Context, string, string) (net.PacketConn, error) {
	panic("公开 TCP 场景不应创建 UDP")
}

func TestFactoryTLSPreflightBeforeRealBind(t *testing.T) {
	factories := map[string]func(LC.AuthServer, C.InboundListenConfig) (io.Closer, error){
		"http": func(c LC.AuthServer, l C.InboundListenConfig) (io.Closer, error) {
			c.AuthStore = auth.Nil
			return HTTP.NewWithConfig(c, l, nil, inbound.WithInName("PUBLIC_TEST"))
		},
		"socks": func(c LC.AuthServer, l C.InboundListenConfig) (io.Closer, error) {
			c.AuthStore = auth.Nil
			return socks.NewWithConfig(c, l, nil, inbound.WithInName("PUBLIC_TEST"))
		},
		"mixed": func(c LC.AuthServer, l C.InboundListenConfig) (io.Closer, error) {
			c.AuthStore = auth.Nil
			return mixed.NewWithConfig(c, l, nil, inbound.WithInName("PUBLIC_TEST"))
		},
	}
	for name, factory := range factories {
		t.Run(name, func(t *testing.T) {
			capture := &publicListenCapture{}
			t.Cleanup(func() {
				if capture.listener != nil {
					if err := capture.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
						t.Error("公开监听清理未确认")
					}
				}
			})
			p := t.TempDir()
			_, err := factory(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", Certificate: filepath.Join(p, "missing.crt"), PrivateKey: filepath.Join(p, "missing.key")}, capture)
			if err == nil {
				t.Fatal("无效公开证书应拒绝构造")
			}
			if capture.calls != 0 {
				t.Fatal("证书失败前创建了实际监听，错误返回丢失资源")
			}
		})
		t.Run(name+"-success", func(t *testing.T) {
			capture := &publicListenCapture{}
			t.Cleanup(func() {
				if capture.listener != nil {
					if err := capture.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
						t.Error("公开监听清理未确认")
					}
				}
			})
			l, err := factory(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0"}, capture)
			if err != nil || l == nil || capture.listener == nil || capture.calls != 1 {
				t.Fatal("正常构造没有返回实际资源")
			}
			address := capture.listener.Addr().String()
			if l.Close() != nil {
				t.Fatal("正常资源关闭失败")
			}
			rebound, err := net.Listen("tcp", address)
			if err != nil {
				t.Fatal("确认关闭后端口仍被占用")
			}
			if rebound.Close() != nil {
				t.Fatal("公开端口对照清理失败")
			}
		})
		t.Run(name+"-tls", func(t *testing.T) {
			capture := &publicListenCapture{}
			t.Cleanup(func() {
				if capture.listener != nil {
					if err := capture.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
						t.Error("公开 TLS 监听清理未确认")
					}
				}
			})
			cfg, roots := publicTLSFixture(t)
			l, err := factory(cfg, capture)
			if err != nil || capture.listener == nil {
				t.Fatal("公开 TLS 监听构造失败")
			}
			t.Cleanup(func() {
				if l.Close() != nil {
					t.Error("TLS 监听清理失败")
				}
			})
			client, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", capture.listener.Addr().String(), &tls.Config{RootCAs: roots, ServerName: "localhost", MinVersion: tls.VersionTLS12})
			if err != nil {
				t.Fatal("正常证书 TLS 握手失败")
			}
			if client.Close() != nil {
				t.Fatal("公开 TLS 客户端清理失败")
			}
		})
	}
}

// 证书与密钥仅在测试进程中生成和消费，不输出、不写入仓库或日志。
func publicTLSFixture(t *testing.T) (LC.AuthServer, *x509.CertPool) {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal("合成测试身份生成失败")
	}
	now := time.Now()
	template := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"localhost"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, pub, key)
	if err != nil {
		t.Fatal("合成证书生成失败")
	}
	encodedKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal("合成身份编码失败")
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(certPEM) {
		t.Fatal("合成信任根设置失败")
	}
	return LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", Certificate: string(certPEM), PrivateKey: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encodedKey}))}, roots
}
