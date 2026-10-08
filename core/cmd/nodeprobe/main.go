// nodeprobe 只探测固定 HTTPS 目标，不监听端口或修改系统网络。
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
	MLog "github.com/metacubex/mihomo/log"
	"github.com/sirupsen/logrus"
)

const maxInput = 1 << 20
const target = "https://www.cloudflare.com/cdn-cgi/trace"

type result struct {
	Index    int    `json:"index"`
	Protocol string `json:"protocol"`
	Stage    string `json:"stage"`
	Error    string `json:"error_class,omitempty"`
	Status   int    `json:"http_status,omitempty"`
	Trace    bool   `json:"trace_present"`
}

func decode(r io.Reader) ([]map[string]any, error) {
	b, err := io.ReadAll(io.LimitReader(r, maxInput+1))
	if err != nil || len(b) > maxInput {
		return nil, errors.New("input_rejected")
	}
	var raw []json.RawMessage
	if json.Unmarshal(b, &raw) != nil || len(raw) == 0 || len(raw) > 4 {
		return nil, errors.New("input_rejected")
	}
	nodes := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		d := json.NewDecoder(bytes.NewReader(item))
		token, err := d.Token()
		if err != nil || token != json.Delim('{') {
			return nil, errors.New("input_rejected")
		}
		n := map[string]any{}
		for d.More() {
			token, err = d.Token()
			key, ok := token.(string)
			if err != nil || !ok {
				return nil, errors.New("input_rejected")
			}
			if _, duplicate := n[key]; duplicate {
				return nil, errors.New("input_rejected")
			}
			var value any
			if d.Decode(&value) != nil {
				return nil, errors.New("input_rejected")
			}
			n[key] = value
		}
		nodes = append(nodes, n)
	}
	counts := map[string]int{}
	for _, n := range nodes {
		kind, _ := n["type"].(string)
		counts[kind]++
		if (kind != "anytls" && kind != "hysteria2") || counts[kind] > 2 {
			return nil, errors.New("input_rejected")
		}
		if host, ok := n["server"].(string); !ok || host == "" {
			return nil, errors.New("input_rejected")
		}
		if p, ok := n["port"].(float64); !ok || p < 1 || p > 65535 || p != float64(int(p)) {
			return nil, errors.New("input_rejected")
		}
		if p, ok := n["password"].(string); !ok || p == "" {
			return nil, errors.New("input_rejected")
		}
		// 仅接受协议所需规范字段；别名、未知键及嵌套链路在核心解析前拒绝。
		for k, v := range n {
			if !validOption(kind, k, v) {
				return nil, errors.New("input_rejected")
			}
		}
		n["name"] = "anonymous-probe"
	}
	return nodes, nil
}

func validOption(kind, key string, value any) bool {
	var category string
	switch key {
	case "port":
		return true
	case "type", "name", "server", "password", "sni", "client-fingerprint":
		category = "string"
	case "skip-cert-verify":
		return value == false
	case "udp":
		_, ok := value.(bool)
		return ok
	case "alpn":
		values, ok := value.([]any)
		if !ok || len(values) > 8 {
			return false
		}
		for _, item := range values {
			text, ok := item.(string)
			if !ok || len(text) > 128 {
				return false
			}
		}
		return true
	default:
		if kind == "anytls" {
			switch key {
			case "idle-session-check-interval", "idle-session-timeout", "min-idle-session":
				category = "integer"
			default:
				return false
			}
		} else {
			switch key {
			case "up", "down", "obfs", "obfs-password", "ports", "hop-interval":
				category = "string"
			default:
				return false
			}
		}
	}
	if category == "string" {
		v, ok := value.(string)
		return ok && len(v) <= 4096
	}
	v, ok := value.(float64)
	return ok && v >= 0 && v <= 3600 && v == float64(int(v))
}

func errorClass(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "timeout"
	}
	var ce *tls.CertificateVerificationError
	if errors.As(err, &ce) {
		return "certificate"
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "peer_closed"
	}
	// 不返回原始错误；协议实现可能把地址或身份标识放入错误中。
	if strings.Contains(strings.ToLower(err.Error()), "authentication") {
		return "authentication"
	}
	return "transport"
}

func probe(ctx context.Context, index int, n map[string]any) result {
	kind := n["type"].(string)
	r := result{Index: index, Protocol: kind, Stage: "parse"}
	p, err := adapter.ParseProxy(n)
	if err != nil {
		r.Error = "configuration"
		return r
	}
	defer p.Close()
	return requestThrough(ctx, index, kind, func(c context.Context, m *C.Metadata) (net.Conn, error) { return p.DialContext(c, m) })
}

func requestThrough(ctx context.Context, index int, kind string, dial func(context.Context, *C.Metadata) (net.Conn, error)) result {
	r := result{Index: index, Protocol: kind, Stage: "request"}
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dial(ctx, &C.Metadata{NetWork: C.TCP, Host: "www.cloudflare.com", DstPort: 443})
		}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	r.Stage = "request"
	response, err := client.Do(req)
	if err != nil {
		r.Error = errorClass(err)
		return r
	}
	defer response.Body.Close()
	r.Status = response.StatusCode
	b, err := io.ReadAll(io.LimitReader(response.Body, 16385))
	if err != nil {
		r.Error = errorClass(err)
		return r
	}
	if len(b) > 16384 {
		r.Error = "response_limit"
		return r
	}
	r.Stage = "response"
	r.Trace = response.StatusCode == 200 && strings.Contains(string(b), "\nip=") && strings.Contains(string(b), "\ntls=")
	return r
}

func main() {
	// 在读取秘密输入前关闭库日志；输出仅为固定字段结果。
	MLog.SetLevel(MLog.SILENT)
	logrus.SetOutput(io.Discard)
	nodes, err := decode(os.Stdin)
	if err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"error_class": "input_rejected"})
		return
	}
	results := make([]result, 0, len(nodes))
	for i, n := range nodes {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		results = append(results, probe(ctx, i, n))
		cancel()
	}
	_ = json.NewEncoder(os.Stdout).Encode(results)
}
