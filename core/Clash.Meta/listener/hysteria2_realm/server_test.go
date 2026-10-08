package hysteria2_realm

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	stdhttp "net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	LC "github.com/metacubex/mihomo/listener/config"
)

type realmTestListenConfig struct {
	listeners  []net.Listener
	failClose  bool
	joinClosed bool
}

func (c *realmTestListenConfig) Listen(ctx context.Context, network, address string) (net.Listener, error) {
	var lc net.ListenConfig
	l, err := lc.Listen(ctx, network, address)
	if err == nil {
		if c.failClose {
			l = &realmFailedClose{Listener: l, joinClosed: c.joinClosed}
			l.(*realmFailedClose).fail.Store(true)
		}
		c.listeners = append(c.listeners, l)
	}
	return l, err
}

type realmFailedClose struct {
	net.Listener
	fail       atomic.Bool
	joinClosed bool
}

func (l *realmFailedClose) Close() error {
	if l.fail.Load() {
		if l.joinClosed {
			return errors.Join(net.ErrClosed, errors.New("公开夹具关闭未确认"))
		}
		return errors.New("公开夹具关闭未确认")
	}
	return l.Listener.Close()
}

func (*realmTestListenConfig) ListenPacket(ctx context.Context, network, address string) (net.PacketConn, error) {
	var lc net.ListenConfig
	return lc.ListenPacket(ctx, network, address)
}

func realmTestConfig(address string) LC.Hysteria2RealmServer {
	return LC.Hysteria2RealmServer{Listen: address, RealmNamePattern: DefaultRealmNamePattern,
		Token: "PUBLIC_FIXTURE_TOKEN", MaxRealms: 10, MaxRealmsPerIP: 4}
}

func TestRealmCloseExistingHTTPConnection(t *testing.T) {
	lc := &realmTestListenConfig{}
	l, err := New(realmTestConfig("127.0.0.1:0"), lc, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	c, err := net.DialTimeout("tcp", l.AddrList()[0].String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(time.Second))
	reader := bufio.NewReader(c)
	request := "GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n"
	if _, err = io.WriteString(c, request); err != nil {
		t.Fatal(err)
	}
	response, err := stdhttp.ReadResponse(reader, nil)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	_ = response.Body.Close()
	if response.StatusCode != 404 {
		t.Fatal("真实 HTTP 服务未建立")
	}
	if err = l.Close(); err != nil {
		t.Fatal(err)
	}
	// 已有 HTTP 连接不能在监听端口关闭后继续使用。
	_, _ = io.WriteString(c, request)
	_, err = stdhttp.ReadResponse(reader, nil)
	if err == nil {
		t.Fatal("关闭后既有 HTTP 连接仍能返回响应")
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("超时不能作为连接关闭证明")
	}
}

func TestRealmPartialBindFailureReleasesEarlierPort(t *testing.T) {
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	lc := &realmTestListenConfig{}
	listener, err := New(realmTestConfig("127.0.0.1:0,"+occupied.Addr().String()), lc, nil)
	if listener != nil {
		defer listener.Close()
	}
	defer func() {
		for _, l := range lc.listeners {
			_ = l.Close()
		}
	}()
	if err == nil || len(lc.listeners) != 1 {
		t.Fatal("必须实际创建第一个端口并在第二次绑定失败")
	}
	rebound, err := net.Listen("tcp", lc.listeners[0].Addr().String())
	if err != nil {
		t.Fatal("构造失败遗失前面已绑定端口", fmt.Sprint(err))
	}
	_ = rebound.Close()
}

func TestRealmPartialBindCleanupFailureRetainsObject(t *testing.T) {
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	lc := &realmTestListenConfig{failClose: true}
	l, err := New(realmTestConfig("127.0.0.1:0,"+occupied.Addr().String()), lc, nil)
	if len(lc.listeners) != 1 {
		t.Fatal("没有实际创建部分资源")
	}
	partial := lc.listeners[0].(*realmFailedClose)
	t.Cleanup(func() { partial.fail.Store(false); _ = partial.Close() })
	if err == nil || l == nil {
		t.Fatal("关闭未知必须保留部分对象及错误")
	}
	partial.fail.Store(false)
	if err = l.Close(); err != nil {
		t.Fatal(err)
	}
	rebound, err := net.Listen("tcp", partial.Addr().String())
	if err != nil {
		t.Fatal("显式成功关闭后仍占用端口")
	}
	_ = rebound.Close()
}

func TestRealmJoinedCloseFailureIsNotDiscarded(t *testing.T) {
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	lc := &realmTestListenConfig{failClose: true, joinClosed: true}
	l, err := New(realmTestConfig("127.0.0.1:0,"+occupied.Addr().String()), lc, nil)
	if len(lc.listeners) != 1 {
		t.Fatal("没有实际创建部分资源")
	}
	partial := lc.listeners[0].(*realmFailedClose)
	t.Cleanup(func() { partial.fail.Store(false); _ = partial.Close() })
	if err == nil || l == nil {
		t.Fatal("混合已关闭与真实失败的错误不能丢弃部分对象")
	}
	partial.fail.Store(false)
	if err = l.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRealmRunningCloseFailureReturnsResponsibility(t *testing.T) {
	lc := &realmTestListenConfig{failClose: true}
	l, err := New(realmTestConfig("127.0.0.1:0"), lc, nil)
	if err != nil {
		t.Fatal(err)
	}
	partial := lc.listeners[0].(*realmFailedClose)
	t.Cleanup(func() { partial.fail.Store(false); _ = partial.Listener.Close(); _ = l.Close() })
	transport := &stdhttp.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &stdhttp.Client{Transport: transport, Timeout: time.Second}
	resp, err := client.Get("http://" + l.AddrList()[0].String() + "/missing")
	if err != nil {
		t.Fatal("实际HTTP服务未开始", err)
	}
	_ = resp.Body.Close()
	done := make(chan error, 1)
	go func() { done <- l.Close() }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("实际监听未关闭不能确认停止")
		}
	case <-time.After(200 * time.Millisecond):
		// 先解除真实Accept等待并回收失败测试，禁止遗留后台关闭任务。
		partial.fail.Store(false)
		_ = partial.Listener.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("失败测试的关闭任务未回收")
		}
		t.Fatal("底层关闭错误导致HTTP Server等待卡住，未返回未知责任")
	}
	partial.fail.Store(false)
	if err = l.Close(); err != nil {
		t.Fatal("显式清理未完成", err)
	}
}

func TestRealmMultipleServersAndConcurrentClose(t *testing.T) {
	l, err := New(realmTestConfig("127.0.0.1:0,127.0.0.1:0"), &realmTestListenConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	transport := &stdhttp.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &stdhttp.Client{Transport: transport, Timeout: time.Second}
	for _, addr := range l.AddrList() {
		resp, err := client.Get("http://" + addr.String() + "/missing")
		if err != nil {
			t.Fatal("每个真实绑定必须独立提供HTTP服务", err)
		}
		_ = resp.Body.Close()
	}
	var group sync.WaitGroup
	for i := 0; i < 4; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if err := l.Close(); err != nil {
				t.Error("重复关闭未确认", err)
			}
		}()
	}
	group.Wait()
	for _, addr := range l.AddrList() {
		rebound, err := net.Listen("tcp", addr.String())
		if err != nil {
			t.Fatal("关闭后必须释放全部绑定")
		}
		_ = rebound.Close()
	}
}

func TestRealmCloseSessionAndEventStream(t *testing.T) {
	l, err := New(realmTestConfig("127.0.0.1:0"), &realmTestListenConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	transport := &stdhttp.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &stdhttp.Client{Transport: transport, Timeout: time.Second}
	base := "http://" + l.AddrList()[0].String() + "/v1/public-fixture"
	req, _ := stdhttp.NewRequest("POST", base, strings.NewReader(`{"addresses":["127.0.0.1:12345"]}`))
	req.Header.Set("Authorization", "Bearer PUBLIC_FIXTURE_TOKEN")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var registered struct {
		SessionID string `json:"session_id"`
	}
	err = json.NewDecoder(resp.Body).Decode(&registered)
	_ = resp.Body.Close()
	if err != nil || resp.StatusCode != 200 || registered.SessionID == "" {
		t.Fatal("真实注册请求失败")
	}
	req, _ = stdhttp.NewRequest("GET", base+"/events", nil)
	req.Header.Set("Authorization", "Bearer "+registered.SessionID)
	events, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer events.Body.Close()
	if events.StatusCode != 200 {
		t.Fatal("实际SSE处理器未开始")
	}
	if err = l.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = io.ReadAll(events.Body); err == nil {
		// EOF也可能是合法空流；下方session状态和handler等待独立验收。
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("超时不能证明SSE关闭")
	}
	l.server.mu.Lock()
	defer l.server.mu.Unlock()
	if len(l.server.realms) != 0 || len(l.server.sessions) != 0 || len(l.server.ipCounts) != 0 {
		t.Fatal("任务退出后仍有有效会话")
	}
}

func TestRealmClosePendingRequestBody(t *testing.T) {
	l, err := New(realmTestConfig("127.0.0.1:0"), &realmTestListenConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	c, err := net.DialTimeout("tcp", l.AddrList()[0].String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(time.Second))
	_, err = io.WriteString(c, "POST /v1/public-body HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer PUBLIC_FIXTURE_TOKEN\r\nContent-Length: 100\r\nExpect: 100-continue\r\n\r\n")
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(c)
	resp, err := stdhttp.ReadResponse(reader, nil)
	if err != nil || resp.StatusCode != 100 {
		t.Fatal("处理器未实际进入请求正文读取")
	}
	_ = resp.Body.Close()
	done := make(chan error, 1)
	go func() { done <- l.Close() }()
	select {
	case err = <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		// 失败时关闭客户端唤醒正文读，回收任务再报告。
		_ = c.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("正文读取关闭任务未回收")
		}
		t.Fatal("关闭未等待并唤醒已准入的请求正文读取")
	}
	_, err = reader.ReadByte()
	if err == nil {
		t.Fatal("已关闭连接仍返回业务数据")
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("超时不能证明正文连接关闭")
	}
}

type realmEmptyWrappedError struct{}

func (realmEmptyWrappedError) Error() string { return "公开未知关闭" }
func (realmEmptyWrappedError) Unwrap() error { return nil }

type realmEmptyJoinedError struct{}

func (realmEmptyJoinedError) Error() string   { return "公开未知聚合关闭" }
func (realmEmptyJoinedError) Unwrap() []error { return nil }

func TestRealmCloseErrorClassification(t *testing.T) {
	unknown := errors.New("公开关闭失败")
	for _, fixture := range []struct {
		name      string
		err       error
		confirmed bool
	}{
		{"无错误", nil, true},
		{"已关闭", net.ErrClosed, true},
		{"单一已关闭包装", fmt.Errorf("公开包装: %w", net.ErrClosed), true},
		{"仅已关闭聚合", errors.Join(net.ErrClosed, net.ErrClosed), true},
		{"实际失败", unknown, false},
		{"混合错误", errors.Join(net.ErrClosed, unknown), false},
		{"包装混合错误", fmt.Errorf("公开包装: %w", errors.Join(net.ErrClosed, unknown)), false},
		{"空单一解包", realmEmptyWrappedError{}, false},
		{"空聚合解包", realmEmptyJoinedError{}, false},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			if (realmCloseError(fixture.err) == nil) != fixture.confirmed {
				t.Fatal("关闭错误分类不能消除未知责任")
			}
		})
	}
}
