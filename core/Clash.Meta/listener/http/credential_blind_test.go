package http

import (
	"bufio"
	"bytes"
	"context"
	H "github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	L "github.com/metacubex/mihomo/log"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// 所有认证值都是明确虚构的fixture；不访问系统代理、Keychain或公网。
const fictionalAuth = "Basic RklDVElPTkFMX1VTRVI6RklDVElPTkFMX1BBU1M="

type blindFixtureTunnel struct{ tcp func(net.Conn, *C.Metadata) }

func (f blindFixtureTunnel) HandleTCPConn(c net.Conn, m *C.Metadata)  { f.tcp(c, m) }
func (f blindFixtureTunnel) HandleUDPPacket(C.UDPPacket, *C.Metadata) {}
func (f blindFixtureTunnel) NatTable() C.NatTable                     { return nil }

func blindDial(t *testing.T, owner *CredentialBlindListener) net.Conn {
	t.Helper()
	client, err := net.DialTimeout("tcp4", owner.Address(), time.Second)
	if err != nil {
		t.Fatal("本地fixture连接失败")
	}
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	return client
}

func TestBlindTrailerIsolationAfterEOFAndTargetAuthorization(t *testing.T) {
	raw := "POST http://fixture.invalid/upload HTTP/1.1\r\nHost: fixture.invalid\r\n" +
		"Proxy-Authorization: " + fictionalAuth + "\r\nAuthorization: FICTIONAL_TARGET_AUTH\r\n" +
		"Transfer-Encoding: chunked\r\nTrailer: X-Safe\r\n\r\n" +
		"1\r\nx\r\n0\r\nProxy-Authorization: " + fictionalAuth + "\r\nX-Safe: yes\r\n\r\n"
	input, err := ReadRequest(bufio.NewReader(strings.NewReader(raw)))
	if err != nil {
		t.Fatal("公开fixture解析失败")
	}
	output, ok := blindOutput(input)
	if !ok {
		t.Fatal("正常声明不应被拒绝")
	}
	var forwarded bytes.Buffer
	if err := output.Write(&forwarded); err != nil {
		t.Fatal("公开fixture转发失败")
	}
	if input.Trailer.Get("Proxy-Authorization") == "" {
		t.Fatal("fixture未验证EOF动态填充")
	}
	if output.Trailer != nil || input.Header.Get("Proxy-Authorization") != "" {
		t.Fatal("输入与输出未隔离")
	}
	if strings.Contains(forwarded.String(), fictionalAuth) || strings.Contains(forwarded.String(), "Proxy-Authorization") {
		t.Fatal("虚构代理认证被转发")
	}
	if !strings.Contains(forwarded.String(), "Authorization: FICTIONAL_TARGET_AUTH") {
		t.Fatal("目标认证被破坏")
	}
}

func TestBlindDeclaredAuthTrailersAndConnectBodyReject(t *testing.T) {
	for _, name := range []string{"Proxy-Authorization", "pRoXy-AuThEnTiCaTe", "Proxy-Authentication-Info"} {
		input := &H.Request{Method: H.MethodPost, Header: make(H.Header), Trailer: H.Header{name: nil}}
		if _, ok := blindOutput(input); ok {
			t.Fatal("认证Trailer声明未拒绝")
		}
	}
	for _, input := range []*H.Request{
		{Method: H.MethodConnect, Header: make(H.Header), ContentLength: 1},
		{Method: H.MethodConnect, Header: make(H.Header), TransferEncoding: []string{"chunked"}},
		{Method: H.MethodConnect, Header: make(H.Header), Trailer: H.Header{"X-Safe": nil}},
	} {
		if _, ok := blindOutput(input); ok {
			t.Fatal("CONNECT正文或Trailer未拒绝")
		}
	}
}

func TestBlindLargeStreamingBodyAndMetadata(t *testing.T) {
	const length = 17 * 1024 * 1024
	result := make(chan bool, 1)
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		defer c.Close()
		input, readErr := H.ReadRequest(bufio.NewReader(c))
		if readErr != nil {
			result <- false
			return
		}
		n, readErr := io.Copy(io.Discard, input.Body)
		result <- readErr == nil && n == length && m.InUser == "" &&
			input.Header.Get("Proxy-Authorization") == "" && input.Header.Get("Authorization") == "FICTIONAL_TARGET_AUTH"
		_, _ = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	defer func() {
		if owner.Close() != nil {
			t.Error("owned停止未完成")
		}
	}()
	_, _ = io.WriteString(client, "POST http://fixture.invalid/upload HTTP/1.1\r\nHost: fixture.invalid\r\n"+
		"Content-Length: 17825792\r\nAuthorization: FICTIONAL_TARGET_AUTH\r\nProxy-Authorization: "+fictionalAuth+"\r\n\r\n")
	// 固定64KiB内存分块；fixture不分配17MiB正文。
	block := bytes.Repeat([]byte("x"), 64*1024)
	for written := 0; written < length; written += len(block) {
		if _, err := client.Write(block); err != nil {
			t.Fatal("大正文流式写入失败")
		}
	}
	response, err := H.ReadResponse(bufio.NewReader(client), nil)
	if err != nil || response.StatusCode != 200 {
		t.Fatal("大正文请求未完成")
	}
	if response.Body != nil {
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
	}
	if !<-result {
		t.Fatal("大正文或认证隔离不变量失败")
	}
}

func TestBlindConnectTailAndTransferredOwnership(t *testing.T) {
	transferred := make(chan net.Conn, 1)
	metadata := make(chan *C.Metadata, 1)
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		transferred <- c
		metadata <- m // 模拟移交后handler返回，但连接仍活跃。
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	_, _ = io.WriteString(client, "CONNECT fixture.invalid:443 HTTP/1.1\r\nHost: fixture.invalid:443\r\n"+
		"Proxy-Authorization: "+fictionalAuth+"\r\n\r\nPUBLIC_TLS_TAIL")
	response, err := H.ReadResponse(bufio.NewReader(client), nil)
	if err != nil || response.StatusCode != 200 {
		t.Fatal("CONNECT未接受")
	}
	routed := <-transferred
	if (<-metadata).InUser != "" {
		t.Fatal("CONNECT产生用户名元数据")
	}
	tail := make([]byte, len("PUBLIC_TLS_TAIL"))
	if _, err := io.ReadFull(routed, tail); err != nil || string(tail) != "PUBLIC_TLS_TAIL" {
		t.Fatal("TLS预读字节丢失")
	}
	if err := owner.Close(); err != nil {
		t.Fatal("移交连接停止未完成")
	}
	if _, err := client.Read(make([]byte, 1)); err == nil {
		t.Fatal("owned socket未关闭")
	}
}

func TestBlindUpgradeAndCloseDuringResponseWait(t *testing.T) {
	started := make(chan struct{})
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		defer c.Close()
		input, err := H.ReadRequest(bufio.NewReader(c))
		if err != nil {
			return
		}
		if input.Header.Get("Proxy-Authorization") != "" || m.InUser != "" {
			t.Error("Upgrade认证未隔离")
		}
		close(started)
		// 不回应101；等待专用Close取消内部pipe。
		_, _ = io.Copy(io.Discard, c)
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	_, _ = io.WriteString(client, "GET http://fixture.invalid/ws HTTP/1.1\r\nHost: fixture.invalid\r\n"+
		"Connection: Upgrade\r\nUpgrade: websocket\r\nProxy-Authorization: "+fictionalAuth+"\r\n\r\n")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("Upgrade路由未开始")
	}
	if owner.Close() != nil {
		t.Fatal("Upgrade等待未被取消")
	}
}

func TestBlindCloseIncompleteCannotReportStopped(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		once.Do(func() { close(entered) })
		<-release
		_ = c.Close()
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	_, _ = io.WriteString(client, "CONNECT fixture.invalid:443 HTTP/1.1\r\n\r\n")
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("fixture未移交")
	}
	if owner.Close() == nil {
		t.Fatal("仍阻塞的handler被误报已停止")
	}
	close(release)
	select {
	case <-owner.handlersDone:
	case <-time.After(time.Second):
		t.Fatal("fixture未自然收束")
	}
	if owner.Close() != nil {
		t.Fatal("最终owned关闭未核验")
	}
}

func TestBlindNoAuthLogOnConnect(t *testing.T) {
	events := L.Subscribe()
	defer L.UnSubscribe(events)
	started := make(chan struct{})
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		if m.InUser != "" {
			t.Error("用户名进入metadata")
		}
		close(started)
		_ = c.Close()
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	_, _ = io.WriteString(client, "CONNECT fixture.invalid:443 HTTP/1.1\r\nProxy-Authorization: "+fictionalAuth+"\r\n\r\n")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("CONNECT未开始")
	}
	if owner.Close() != nil {
		t.Fatal("owned停止未完成")
	}
	// 公开屏障只用于确认日志流已消费，不返回任何日志正文。
	L.Debugln("PUBLIC_BLIND_FIXTURE_BARRIER")
	deadline := time.After(time.Second)
	for {
		select {
		case event := <-events:
			if strings.Contains(event.Payload, "Auth success") || strings.Contains(event.Payload, "FICTIONAL_USER") ||
				strings.Contains(event.Payload, fictionalAuth) {
				t.Fatal("虚构认证进入日志")
			}
			if event.Payload == "PUBLIC_BLIND_FIXTURE_BARRIER" {
				return
			}
		case <-deadline:
			t.Fatal("日志屏障未完成")
		}
	}
}

func TestBlindUpgradeTransparentBytes(t *testing.T) {
	outcome := make(chan bool, 1)
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		defer c.Close()
		request, err := H.ReadRequest(bufio.NewReader(c))
		if err != nil {
			outcome <- false
			return
		}
		outcome <- request.Header.Get("Proxy-Authorization") == "" && request.Header.Get("Authorization") == "FICTIONAL_TARGET_AUTH" && m.InUser == ""
		_, _ = io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
		_, _ = io.Copy(c, c) // 仅内部pipe回显，无外部网络。
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	defer func() {
		if owner.Close() != nil {
			t.Error("Upgrade停止未完成")
		}
	}()
	_, _ = io.WriteString(client, "GET http://fixture.invalid/ws HTTP/1.1\r\nHost: fixture.invalid\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nAuthorization: FICTIONAL_TARGET_AUTH\r\nProxy-Authorization: "+fictionalAuth+"\r\n\r\n")
	reader := bufio.NewReader(client)
	response, err := H.ReadResponse(reader, nil)
	if err != nil || response.StatusCode != 101 {
		t.Fatal("Upgrade握手未完成")
	}
	if !<-outcome {
		t.Fatal("Upgrade输出或metadata不满足隔离")
	}
	_, _ = io.WriteString(client, "PUBLIC_WEBSOCKET_BYTES")
	got := make([]byte, len("PUBLIC_WEBSOCKET_BYTES"))
	if _, err := io.ReadFull(reader, got); err != nil || string(got) != "PUBLIC_WEBSOCKET_BYTES" {
		t.Fatal("Upgrade透明字节不符")
	}
}

func TestBlindLargeStreamingDownload(t *testing.T) {
	const length = 17 * 1024 * 1024
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		defer c.Close()
		request, err := H.ReadRequest(bufio.NewReader(c))
		if err != nil || request.Header.Get("Proxy-Authorization") != "" || m.InUser != "" {
			return
		}
		_, _ = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 17825792\r\nConnection: close\r\n\r\n")
		block := bytes.Repeat([]byte("x"), 64*1024)
		for written := 0; written < length; written += len(block) {
			if _, err := c.Write(block); err != nil {
				return
			}
		}
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	defer func() {
		if owner.Close() != nil {
			t.Error("owned停止未完成")
		}
	}()
	_, _ = io.WriteString(client, "GET http://fixture.invalid/large HTTP/1.1\r\nHost: fixture.invalid\r\n\r\n")
	response, err := H.ReadResponse(bufio.NewReader(client), nil)
	if err != nil {
		t.Fatal("大下载响应失败")
	}
	n, err := io.Copy(io.Discard, response.Body)
	_ = response.Body.Close()
	if err != nil || n != length {
		t.Fatal("大下载未完整流式传输")
	}
}

func TestBlindAcceptedCapacityAndHeaderSize(t *testing.T) {
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) { _ = c.Close() }})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	clients := make([]net.Conn, 0, blindConnections)
	defer func() {
		for _, c := range clients {
			_ = c.Close()
		}
		if owner.Close() != nil {
			t.Error("owned停止未完成")
		}
	}()
	for i := 0; i < blindConnections; i++ {
		clients = append(clients, blindDial(t, owner))
	}
	until := time.Now().Add(time.Second)
	for {
		owner.mu.Lock()
		count := len(owner.owned)
		owner.mu.Unlock()
		if count == blindConnections {
			break
		}
		if time.Now().After(until) {
			t.Fatal("并发fixture未就绪")
		}
		time.Sleep(time.Millisecond)
	}
	extra := blindDial(t, owner)
	defer extra.Close()
	if _, err := extra.Read(make([]byte, 1)); err == nil {
		t.Fatal("额外并发连接未关闭")
	}
	reader := bufio.NewReaderSize(strings.NewReader(strings.Repeat("X", blindHeaderBytes)), blindHeaderBytes)
	if blindReadHeader(reader) == nil {
		t.Fatal("超长头未被拒绝")
	}
}

// fixture只缩短内核等待时间，保留并检查生产函数设置的15秒头预算。
type blindDeadlineFixture struct {
	net.Conn
	requested time.Duration
}

func (c *blindDeadlineFixture) SetDeadline(deadline time.Time) error {
	c.requested = time.Until(deadline)
	return c.Conn.SetDeadline(time.Now().Add(10 * time.Millisecond))
}
func TestBlindSlowHeaderClosesOnlyOwnedConnection(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	ctx, cancel := context.WithCancel(context.Background())
	owner := &CredentialBlindListener{owned: make(map[*blindConn]struct{})}
	raw := &blindDeadlineFixture{Conn: server}
	c := &blindConn{Conn: raw, owner: owner, ctx: ctx, cancel: cancel}
	owner.owned[c] = struct{}{}
	done := make(chan struct{})
	go func() {
		handleCredentialBlind(c, blindFixtureTunnel{tcp: func(net.Conn, *C.Metadata) { t.Error("慢头不应进入路由") }})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("慢头未有界关闭")
	}
	if raw.requested < 14*time.Second || raw.requested > blindHeaderTime {
		t.Fatal("头预算发生变化")
	}
	owner.mu.Lock()
	count := len(owner.owned)
	owner.mu.Unlock()
	if count != 0 {
		t.Fatal("慢头socket未解除所有权")
	}
}

func TestBlindHTTPAndUpgradeUncancellableInternalRouteCannotReportStopped(t *testing.T) {
	for _, upgrade := range []bool{false, true} {
		t.Run(map[bool]string{false: "HTTP", true: "Upgrade"}[upgrade], func(t *testing.T) {
			entered := make(chan struct{})
			release := make(chan struct{})
			owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
				close(entered)
				<-release // 故意无视pipe关闭，验证实际内部调用退出而不是外层返回。
				_ = c.Close()
			}})
			if err != nil {
				t.Fatal("入口fixture创建失败")
			}
			client := blindDial(t, owner)
			defer client.Close()
			request := "GET http://fixture.invalid/wait HTTP/1.1\r\nHost: fixture.invalid\r\n"
			if upgrade {
				request += "Connection: Upgrade\r\nUpgrade: websocket\r\n"
			}
			_, _ = io.WriteString(client, request+"\r\n")
			select {
			case <-entered:
			case <-time.After(time.Second):
				t.Fatal("内部路由未开始")
			}
			if owner.Close() == nil {
				t.Fatal("内部路由仍阻塞却报告已停止")
			}
			close(release)
			select {
			case <-owner.handlersDone:
			case <-time.After(time.Second):
				t.Fatal("释放后未自然退出")
			}
			if owner.Close() != nil {
				t.Fatal("释放后仍未核验停止")
			}
		})
	}
}

func TestBlindHTTPClientEOFWithoutBodyAndAfterBodyCancelsSilentUpstream(t *testing.T) {
	for _, body := range []string{"", "PUBLIC_BODY"} {
		t.Run(map[bool]string{true: "NoBody", false: "BodyEOF"}[body == ""], func(t *testing.T) {
			requestRead := make(chan struct{})
			routeExited := make(chan struct{})
			owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
				defer close(routeExited)
				defer c.Close()
				request, err := H.ReadRequest(bufio.NewReader(c))
				if err != nil {
					return
				}
				if request.Body != nil {
					_, _ = io.Copy(io.Discard, request.Body)
					_ = request.Body.Close()
				}
				close(requestRead)
				_, _ = io.Copy(io.Discard, c) // 上游不响应，等客户端EOF取消pipe。
			}})
			if err != nil {
				t.Fatal("入口fixture创建失败")
			}
			client := blindDial(t, owner)
			request := "POST http://fixture.invalid/wait HTTP/1.1\r\nHost: fixture.invalid\r\n"
			if body != "" {
				request += "Content-Length: 11\r\n"
			}
			_, _ = io.WriteString(client, request+"\r\n"+body)
			select {
			case <-requestRead:
			case <-time.After(time.Second):
				t.Fatal("请求正文未读完")
			}
			_ = client.Close()
			select {
			case <-routeExited:
			case <-time.After(time.Second):
				t.Fatal("客户端EOF未取消静默上游")
			}
			until := time.Now().Add(time.Second)
			for {
				owner.mu.Lock()
				count := len(owner.owned)
				owner.mu.Unlock()
				if count == 0 {
					break
				}
				if time.Now().After(until) {
					t.Fatal("客户端关闭后slot未释放")
				}
				time.Sleep(time.Millisecond)
			}
			if owner.Close() != nil {
				t.Fatal("EOF watcher或路由停止未完成")
			}
		})
	}
}
