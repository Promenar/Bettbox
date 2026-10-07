package http

import (
	"bufio"
	H "github.com/metacubex/http"
	A "github.com/metacubex/mihomo/component/auth"
	C "github.com/metacubex/mihomo/constant"
	LA "github.com/metacubex/mihomo/listener/auth"
	"io"
	"net"
	"testing"
	"time"
)

// 默认入口必须保持认证与用户归属；全部账号均为虚构fixture。
func TestDefaultConnectAuthenticationRemainsRequired(t *testing.T) {
	for _, tc := range []struct {
		name, header string
		status       int
		routed       bool
	}{
		{"missing", "", 407, false},
		{"invalid", "Basic RklDVElPTkFMX1VTRVI6V1JPTkc=", 403, false},
		{"accepted", fictionalAuth, 200, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server, client := net.Pipe()
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(3 * time.Second))
			routed := make(chan string, 1)
			done := make(chan struct{})
			tunnel := blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
				routed <- m.InUser
				_ = c.Close()
			}}
			store := LA.NewAuthStore(A.NewAuthenticator([]A.AuthUser{{User: "FICTIONAL_USER", Pass: "FICTIONAL_PASS"}}))
			go func() { defer close(done); HandleConn(server, tunnel, store) }()
			request := "CONNECT fixture.invalid:443 HTTP/1.1\r\nHost: fixture.invalid\r\n"
			if tc.header != "" {
				request += "Proxy-Authorization: " + tc.header + "\r\n"
			}
			if _, err := io.WriteString(client, request+"\r\n"); err != nil {
				t.Fatal("默认入口fixture写入失败")
			}
			resp, err := H.ReadResponse(bufio.NewReader(client), nil)
			if err != nil || resp.StatusCode != tc.status {
				t.Fatal("默认入口认证响应发生变化")
			}
			_ = client.Close()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("默认入口fixture未退出")
			}
			select {
			case user := <-routed:
				if !tc.routed || user != "FICTIONAL_USER" {
					t.Fatal("默认入口用户归属发生变化")
				}
			default:
				if tc.routed {
					t.Fatal("正确认证未进入路由")
				}
			}
		})
	}
}
