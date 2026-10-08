package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func fixture(kind string) map[string]any {
	return map[string]any{"type": kind, "server": "example.invalid", "port": 443, "password": "public-test-placeholder", "name": "private-looking-name"}
}

func TestDecodeBoundaries(t *testing.T) {
	for _, kind := range []string{"anytls", "hysteria2"} {
		b, _ := json.Marshal([]map[string]any{fixture(kind)})
		n, err := decode(strings.NewReader(string(b)))
		if err != nil || n[0]["name"] != "anonymous-probe" {
			t.Fatal("有效协议或匿名边界失败")
		}
	}
	for _, input := range []string{"", "[]", "{}", "[null]", strings.Repeat("x", maxInput+1)} {
		if _, err := decode(strings.NewReader(input)); err == nil || err.Error() != "input_rejected" {
			t.Fatal("无效输入必须固定拒绝")
		}
	}
}

func TestRejectUnsafeOptionsAndLimits(t *testing.T) {
	for _, key := range []string{"skip-cert-verify", "dialer-proxy", "interface-name", "routing-mark", "certificate", "private-key"} {
		n := fixture("anytls")
		n[key] = true
		b, _ := json.Marshal([]map[string]any{n})
		if _, err := decode(strings.NewReader(string(b))); err == nil {
			t.Fatalf("危险项未拒绝: %s", key)
		}
	}
	for _, nodes := range [][]map[string]any{{fixture("direct")}, {fixture("anytls"), fixture("anytls"), fixture("anytls")}} {
		b, _ := json.Marshal(nodes)
		if _, err := decode(strings.NewReader(string(b))); err == nil {
			t.Fatal("类型或次数限制未执行")
		}
	}
	for _, port := range []any{0, 65536, 1.5, "443"} {
		n := fixture("anytls")
		n["port"] = port
		b, _ := json.Marshal([]map[string]any{n})
		if _, err := decode(strings.NewReader(string(b))); err == nil {
			t.Fatal("端口边界未执行")
		}
	}
}

func TestErrorOutputDoesNotExposeSource(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{{nil, ""}, {context.DeadlineExceeded, "timeout"}, {io.EOF, "peer_closed"}, {errors.New("authentication public-placeholder"), "authentication"}, {errors.New("private-looking-address public-placeholder"), "transport"}} {
		if got := errorClass(tc.err); got != tc.want {
			t.Fatalf("分类不符: %s", got)
		}
	}
}

func TestParserAliasCannotBypassNetworkPolicy(t *testing.T) {
	for _, key := range []string{"skip_cert_verify", "SKIP-CERT-VERIFY", "Dialer_Proxy", "Certificate", "private_key"} {
		n := fixture("anytls")
		n[key] = true
		b, _ := json.Marshal([]map[string]any{n})
		if _, err := decode(strings.NewReader(string(b))); err == nil {
			t.Fatalf("解析器别名绕过限制: %s", key)
		}
	}
}

func TestRejectNestedChainsUnknownAndDuplicateKeys(t *testing.T) {
	for _, key := range []string{"realm-opts", "shadow-tls-opts", "restls-opts", "jls-opts", "ech-opts", "extra-field"} {
		n := fixture("hysteria2")
		n[key] = map[string]any{"skip-cert-verify": true, "server-url": "https://example.invalid", "private-key": "public-placeholder"}
		b, _ := json.Marshal([]map[string]any{n})
		if _, err := decode(strings.NewReader(string(b))); err == nil {
			t.Fatalf("额外功能未拒绝: %s", key)
		}
	}
	input := `[{"type":"anytls","server":"example.invalid","port":443,"password":"first","password":"second"}]`
	if _, err := decode(strings.NewReader(input)); err == nil {
		t.Fatal("重复键未拒绝")
	}
}

func TestRequestFixedTargetAndRejectsUntrustedTLS(t *testing.T) {
	s := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("不可信TLS不得进入HTTP处理") }))
	defer s.Close()
	t.Setenv("HTTPS_PROXY", "http://example.invalid:9999")
	called := false
	r := requestThrough(context.Background(), 0, "anytls", func(ctx context.Context, m *C.Metadata) (net.Conn, error) {
		called = true
		if m.Host != "www.cloudflare.com" || m.DstPort != 443 || m.NetWork != C.TCP {
			t.Fatal("固定目标发生改变")
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp", s.Listener.Addr().String())
	})
	if !called || r.Error != "certificate" || r.Status != 0 {
		t.Fatalf("TLS边界不符: %+v", r)
	}
}

func TestRequestDeadlineIsClassified(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	r := requestThrough(ctx, 0, "hysteria2", func(ctx context.Context, _ *C.Metadata) (net.Conn, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	})
	if r.Error != "timeout" {
		t.Fatalf("超时未正确分类: %+v", r)
	}
}
