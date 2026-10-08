package listener_test

import (
	"bufio"
	"context"
	CRAND "crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net"
	STDHTTP "net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	CAUTH "github.com/metacubex/mihomo/component/auth"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/auth"
	LC "github.com/metacubex/mihomo/listener/config"
	HTTP "github.com/metacubex/mihomo/listener/http"
	"github.com/metacubex/mihomo/listener/mixed"
	"github.com/metacubex/mihomo/listener/socks"
	"github.com/metacubex/mihomo/transport/socks4"
	"github.com/metacubex/mihomo/transport/socks5"
)

type tcpLifecycleTunnel struct{ handle func(net.Conn, *C.Metadata) }

func (t tcpLifecycleTunnel) HandleTCPConn(c net.Conn, m *C.Metadata) { t.handle(c, m) }
func (t tcpLifecycleTunnel) HandleUDPPacket(C.UDPPacket, *C.Metadata) {
	panic("公开TCP回归不应创建UDP路由")
}
func (t tcpLifecycleTunnel) NatTable() C.NatTable { return nil }

type tcpLifecycleFactory struct {
	name     string
	protocol string
	create   func(LC.AuthServer, C.InboundListenConfig, C.Tunnel) (io.Closer, error)
}

func tcpLifecycleFactories() []tcpLifecycleFactory {
	return []tcpLifecycleFactory{
		{"HTTP", "http", func(c LC.AuthServer, l C.InboundListenConfig, t C.Tunnel) (io.Closer, error) {
			return HTTP.NewWithConfig(c, l, t, inbound.WithInName("PUBLIC_TCP_TEST"))
		}},
		{"SOCKS", "socks", func(c LC.AuthServer, l C.InboundListenConfig, t C.Tunnel) (io.Closer, error) {
			return socks.NewWithConfig(c, l, t, inbound.WithInName("PUBLIC_TCP_TEST"))
		}},
		{"Mixed-HTTP", "http", func(c LC.AuthServer, l C.InboundListenConfig, t C.Tunnel) (io.Closer, error) {
			return mixed.NewWithConfig(c, l, t, inbound.WithInName("PUBLIC_TCP_TEST"))
		}},
		{"Mixed-SOCKS", "socks", func(c LC.AuthServer, l C.InboundListenConfig, t C.Tunnel) (io.Closer, error) {
			return mixed.NewWithConfig(c, l, t, inbound.WithInName("PUBLIC_TCP_TEST"))
		}},
	}
}
func tcpLifecycleClient(t *testing.T, address, protocol string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", address, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	_ = c.SetDeadline(time.Now().Add(time.Second))
	if protocol == "http" {
		_, err = io.WriteString(c, "CONNECT localhost:80 HTTP/1.1\r\nHost: localhost:80\r\n\r\n")
		if err != nil {
			t.Fatal(err)
		}
		reader := bufio.NewReader(c)
		line, err := reader.ReadString('\n')
		if err != nil || line != "HTTP/1.1 200 Connection established\r\n" {
			t.Fatal("公开CONNECT没有正常握手")
		}
		line, err = reader.ReadString('\n')
		if err != nil || line != "\r\n" {
			t.Fatal("公开CONNECT响应头错误")
		}
	} else {
		if _, err = socks5.ClientHandshake(c, socks5.ParseAddr("127.0.0.1:80"), socks5.CmdConnect, nil); err != nil {
			t.Fatal("公开SOCKS握手失败")
		}
	}
	_ = c.SetDeadline(time.Time{})
	return c
}

func TestTCPProtocolCloseStopsActualAcceptedHandler(t *testing.T) {
	for _, factory := range tcpLifecycleFactories() {
		t.Run(factory.name, func(t *testing.T) {
			entered := make(chan net.Conn, 1)
			finished := make(chan struct{})
			capture := &publicListenCapture{}
			tunnel := tcpLifecycleTunnel{handle: func(c net.Conn, _ *C.Metadata) { entered <- c; defer close(finished); _, _ = io.Copy(io.Discard, c) }}
			l, err := factory.create(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", AuthStore: auth.Nil}, capture, tunnel)
			if err != nil {
				t.Fatal(err)
			}
			peer := tcpLifecycleClient(t, capture.listener.Addr().String(), factory.protocol)
			var server net.Conn
			select {
			case server = <-entered:
			case <-time.After(time.Second):
				t.Fatal("真实协议未进入handler")
			}
			t.Cleanup(func() { _ = server.Close(); _ = l.Close(); <-finished })
			if err := l.Close(); err != nil {
				t.Fatal(err)
			}
			select {
			case <-finished:
			case <-time.After(200 * time.Millisecond):
				t.Fatal("Close成功后实际协议handler仍读取旧socket")
			}
			_ = peer.SetReadDeadline(time.Now().Add(time.Second))
			_, err = peer.Read(make([]byte, 1))
			var timeout net.Error
			if err == nil || (errors.As(err, &timeout) && timeout.Timeout()) {
				t.Fatal("Close成功后客户端连接仍开放")
			}
		})
	}
}

func TestTCPProtocolCloseRetainsBlockedDelegateUntilRetry(t *testing.T) {
	for _, factory := range tcpLifecycleFactories() {
		t.Run(factory.name, func(t *testing.T) {
			entered := make(chan net.Conn, 1)
			release := make(chan struct{})
			finished := make(chan struct{})
			capture := &publicListenCapture{}
			tunnel := tcpLifecycleTunnel{handle: func(c net.Conn, _ *C.Metadata) { entered <- c; defer close(finished); <-release }}
			l, err := factory.create(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", AuthStore: auth.Nil}, capture, tunnel)
			if err != nil {
				t.Fatal(err)
			}
			_ = tcpLifecycleClient(t, capture.listener.Addr().String(), factory.protocol)
			server := <-entered
			firstErr := l.Close()
			close(release)
			secondErr := l.Close()
			t.Cleanup(func() { _ = server.Close(); _ = l.Close(); <-finished })
			if firstErr == nil || secondErr != nil {
				t.Fatalf("未退出任务/显式重试结果错误：失败=%t成功=%t", firstErr != nil, secondErr == nil)
			}
		})
	}
}

type tcpLifecycleCaptureListener struct {
	net.Listener
	accepted chan net.Conn
}

func (l tcpLifecycleCaptureListener) Accept() (net.Conn, error) {
	c, e := l.Listener.Accept()
	if e == nil {
		l.accepted <- c
	}
	return c, e
}

type tcpLifecycleCaptureConfig struct {
	listener net.Listener
	accepted chan net.Conn
}

func (c *tcpLifecycleCaptureConfig) Listen(_ context.Context, network, address string) (net.Listener, error) {
	l, e := net.Listen(network, address)
	if e != nil {
		return nil, e
	}
	c.listener = l
	return tcpLifecycleCaptureListener{l, c.accepted}, nil
}
func (*tcpLifecycleCaptureConfig) ListenPacket(context.Context, string, string) (net.PacketConn, error) {
	panic("公开TLS回归不应创建UDP")
}

func TestTCPProtocolCloseInterruptsActualTLSHandshake(t *testing.T) {
	for _, factory := range tcpLifecycleFactories() {
		t.Run(factory.name, func(t *testing.T) {
			capture := &tcpLifecycleCaptureConfig{accepted: make(chan net.Conn, 1)}
			cfg, _ := publicTLSFixture(t)
			cfg.AuthStore = auth.Nil
			l, err := factory.create(cfg, capture, nil)
			if err != nil {
				t.Fatal(err)
			}
			peer, err := net.DialTimeout("tcp", capture.listener.Addr().String(), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			server := <-capture.accepted
			t.Cleanup(func() { _ = peer.Close(); _ = server.Close(); _ = l.Close() })
			// 已建立TCP但不发送TLS ClientHello，实际协议读仍在等待握手。
			if err := l.Close(); err != nil {
				t.Fatal(err)
			}
			_ = peer.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			_, err = peer.Read(make([]byte, 1))
			var timeout net.Error
			if err == nil || (errors.As(err, &timeout) && timeout.Timeout()) {
				t.Fatal("未完成TLS握手连接在Close成功后仍开放")
			}
		})
	}
}

func TestTCPProtocolHTTPKeepAliveRetainsPipeReuseAndStopsRoute(t *testing.T) {
	for _, factory := range tcpLifecycleFactories() {
		if factory.protocol != "http" {
			continue
		}
		t.Run(factory.name, func(t *testing.T) {
			var routes atomic.Int32
			ended := make(chan struct{}, 8)
			tunnel := tcpLifecycleTunnel{handle: func(c net.Conn, _ *C.Metadata) {
				routes.Add(1)
				defer func() { _ = c.Close(); ended <- struct{}{} }()
				reader := bufio.NewReader(c)
				for {
					req, err := STDHTTP.ReadRequest(reader)
					if err != nil {
						return
					}
					_ = req.Body.Close()
					if _, err = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"); err != nil {
						return
					}
				}
			}}
			capture := &publicListenCapture{}
			l, err := factory.create(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", AuthStore: auth.Nil}, capture, tunnel)
			if err != nil {
				t.Fatal(err)
			}
			peer, err := net.DialTimeout("tcp", capture.listener.Addr().String(), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = peer.Close(); _ = l.Close() })
			_ = peer.SetDeadline(time.Now().Add(3 * time.Second))
			reader := bufio.NewReader(peer)
			for i := 0; i < 3; i++ {
				if _, err = io.WriteString(peer, "GET http://public.invalid/test HTTP/1.1\r\nHost: public.invalid\r\nProxy-Connection: keep-alive\r\n\r\n"); err != nil {
					t.Fatal(err)
				}
				response, err := STDHTTP.ReadResponse(reader, nil)
				if err != nil {
					t.Fatal(err)
				}
				body, err := io.ReadAll(response.Body)
				_ = response.Body.Close()
				if err != nil || response.StatusCode != 200 || string(body) != "ok" {
					t.Fatal("真实HTTP请求响应错误")
				}
			}
			if routes.Load() != 1 {
				t.Fatal("HTTP内部连接复用行为改变")
			}
			if err := l.Close(); err != nil {
				t.Fatal(err)
			}
			select {
			case <-ended:
			default:
				t.Fatal("内部HTTP路由在成功Close后未退出")
			}
		})
	}
}

func TestTCPProtocolUpgradeBidirectionalAndStop(t *testing.T) {
	for _, factory := range tcpLifecycleFactories() {
		if factory.protocol != "http" {
			continue
		}
		t.Run(factory.name, func(t *testing.T) {
			entered := make(chan struct{})
			ended := make(chan struct{})
			tunnel := tcpLifecycleTunnel{handle: func(c net.Conn, _ *C.Metadata) {
				defer func() { _ = c.Close(); close(ended) }()
				reader := bufio.NewReader(c)
				request, err := STDHTTP.ReadRequest(reader)
				if err != nil {
					return
				}
				_ = request.Body.Close()
				if _, err = io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: public-test\r\n\r\n"); err != nil {
					return
				}
				close(entered)
				_, _ = io.Copy(c, reader)
			}}
			capture := &publicListenCapture{}
			l, err := factory.create(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", AuthStore: auth.Nil}, capture, tunnel)
			if err != nil {
				t.Fatal(err)
			}
			peer, err := net.DialTimeout("tcp", capture.listener.Addr().String(), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = peer.Close(); _ = l.Close() })
			_ = peer.SetDeadline(time.Now().Add(3 * time.Second))
			_, err = io.WriteString(peer, "GET http://public.invalid/upgrade HTTP/1.1\r\nHost: public.invalid\r\nConnection: Upgrade\r\nUpgrade: public-test\r\n\r\n")
			if err != nil {
				t.Fatal(err)
			}
			reader := bufio.NewReader(peer)
			response, err := STDHTTP.ReadResponse(reader, nil)
			if err != nil || response.StatusCode != 101 {
				t.Fatal("真实Upgrade失败")
			}
			<-entered
			_, err = peer.Write([]byte("echo"))
			if err != nil {
				t.Fatal(err)
			}
			b := make([]byte, 4)
			if _, err = io.ReadFull(reader, b); err != nil || string(b) != "echo" {
				t.Fatal("Upgrade双向数据失败")
			}
			if err := l.Close(); err != nil {
				t.Fatal(err)
			}
			select {
			case <-ended:
			default:
				t.Fatal("Upgrade路由在Close成功后未退出")
			}
		})
	}
}

func TestTCPProtocolSOCKS4AndUDPAssociateControlStop(t *testing.T) {
	for _, factory := range tcpLifecycleFactories() {
		if factory.protocol != "socks" {
			continue
		}
		for _, protocol := range []string{"socks4", "udp-control"} {
			t.Run(factory.name+protocol, func(t *testing.T) {
				capture := &publicListenCapture{}
				entered := make(chan net.Conn, 1)
				ended := make(chan struct{})
				tunnel := tcpLifecycleTunnel{handle: func(c net.Conn, _ *C.Metadata) { entered <- c; defer close(ended); _, _ = io.Copy(io.Discard, c) }}
				l, err := factory.create(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", AuthStore: auth.Nil}, capture, tunnel)
				if err != nil {
					t.Fatal(err)
				}
				peer, err := net.DialTimeout("tcp", capture.listener.Addr().String(), time.Second)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = peer.Close(); _ = l.Close() })
				_ = peer.SetDeadline(time.Now().Add(time.Second))
				if protocol == "socks4" {
					if err = socks4.ClientHandshake(peer, "127.0.0.1:80", socks4.CmdConnect, ""); err != nil {
						t.Fatal(err)
					}
					select {
					case <-entered:
					case <-time.After(time.Second):
						t.Fatal("SOCKS4未进入真实route")
					}
				} else {
					if _, err = socks5.ClientHandshake(peer, socks5.ParseAddr("127.0.0.1:80"), socks5.CmdUDPAssociate, nil); err != nil {
						t.Fatal(err)
					}
				}
				if err := l.Close(); err != nil {
					t.Fatal(err)
				}
				_, err = peer.Read(make([]byte, 1))
				var timeout net.Error
				if err == nil || (errors.As(err, &timeout) && timeout.Timeout()) {
					t.Fatal("SOCKS控制socket未关闭")
				}
				if protocol == "socks4" {
					select {
					case <-ended:
					default:
						t.Fatal("SOCKS4任务未退出")
					}
				}
			})
		}
	}
}

func TestTCPProtocolHTTPAuthenticationEachRequestAndUserSwitch(t *testing.T) {
	// 一次性测试口令只在进程内生成，不输出或写入文件。
	token := make([]byte, 24)
	if _, err := CRAND.Read(token); err != nil {
		t.Fatal("公开测试身份生成失败")
	}
	pass := base64.StdEncoding.EncodeToString(token)
	store := auth.NewAuthStore(CAUTH.NewAuthenticator([]CAUTH.AuthUser{{User: "public-one", Pass: pass}, {User: "public-two", Pass: pass}}))
	for _, factory := range tcpLifecycleFactories() {
		if factory.protocol != "http" {
			continue
		}
		t.Run(factory.name, func(t *testing.T) {
			users := make(chan string, 8)
			tunnel := tcpLifecycleTunnel{handle: func(c net.Conn, m *C.Metadata) {
				users <- m.InUser
				defer c.Close()
				reader := bufio.NewReader(c)
				for {
					req, err := STDHTTP.ReadRequest(reader)
					if err != nil {
						return
					}
					_ = req.Body.Close()
					if _, err = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"); err != nil {
						return
					}
				}
			}}
			capture := &publicListenCapture{}
			l, err := factory.create(LC.AuthServer{Enable: true, Listen: "127.0.0.1:0", AuthStore: store}, capture, tunnel)
			if err != nil {
				t.Fatal(err)
			}
			peer, err := net.DialTimeout("tcp", capture.listener.Addr().String(), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = peer.Close(); _ = l.Close() })
			_ = peer.SetDeadline(time.Now().Add(3 * time.Second))
			reader := bufio.NewReader(peer)
			for i, user := range []string{"public-one", "public-one", "public-two", "public-rejected"} {
				value := base64.StdEncoding.EncodeToString([]byte(user + ":" + pass))
				request := "GET http://public.invalid/test HTTP/1.1\r\nHost: public.invalid\r\nProxy-Connection: keep-alive\r\nProxy-Authorization: Basic " + value + "\r\n\r\n"
				if _, err = io.WriteString(peer, request); err != nil {
					t.Fatal("测试认证请求发送失败")
				}
				response, err := STDHTTP.ReadResponse(reader, nil)
				if err != nil {
					t.Fatal("测试认证响应读取失败")
				}
				_, _ = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
				expected := 200
				if i == 3 {
					expected = 403
				}
				if response.StatusCode != expected {
					t.Fatalf("第%d个请求认证状态错误：%d", i+1, response.StatusCode)
				}
			}
			if err := l.Close(); err != nil {
				t.Fatal(err)
			}
			if len(users) != 2 {
				t.Fatal("认证用户变化没有隔离复用或拒绝请求进入route")
			}
			if <-users != "public-one" || <-users != "public-two" {
				t.Fatal("真实route用户元数据错误")
			}
		})
	}
}
