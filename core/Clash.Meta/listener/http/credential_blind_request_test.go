package http

import (
	"bufio"
	"context"
	"errors"
	H "github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

type blindReadDeadlineFixture struct {
	net.Conn
	mu          sync.Mutex
	calls       []bool
	failWake    bool
	failRestore bool
	readStarted chan struct{}
	readOnce    sync.Once
}

func (c *blindReadDeadlineFixture) Read(p []byte) (int, error) {
	c.readOnce.Do(func() { close(c.readStarted) })
	return c.Conn.Read(p)
}
func (c *blindReadDeadlineFixture) SetReadDeadline(deadline time.Time) error {
	c.mu.Lock()
	c.calls = append(c.calls, deadline.IsZero())
	c.mu.Unlock()
	if (!deadline.IsZero() && c.failWake) || (deadline.IsZero() && c.failRestore) {
		return errors.New("fixture读期限失败")
	}
	return c.Conn.SetReadDeadline(deadline)
}
func blindStatePipe() (*blindRequestState, *blindReadDeadlineFixture, net.Conn) {
	server, client := net.Pipe()
	raw := &blindReadDeadlineFixture{Conn: server, readStarted: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	owner := &CredentialBlindListener{owned: make(map[*blindConn]struct{})}
	c := &blindConn{Conn: raw, owner: owner, ctx: ctx, cancel: cancel}
	owner.owned[c] = struct{}{}
	state := newBlindRequest(c, bufio.NewReaderSize(c, blindHeaderBytes+1))
	return state, raw, client
}
func blindJoinFixture(t *testing.T, state *blindRequestState) {
	t.Helper()
	state.mu.Lock()
	started := state.watcherStarted
	state.mu.Unlock()
	if started {
		select {
		case <-state.joined:
		case <-time.After(time.Second):
			t.Fatal("fixture watcher未退出")
		}
	}
}

func TestBlindRequestStopJoinsAndRestoresReadOnlyDeadline(t *testing.T) {
	state, raw, client := blindStatePipe()
	defer client.Close()
	defer state.conn.Close()
	state.onBodyEOF()
	select {
	case <-raw.readStarted:
	case <-time.After(time.Second):
		t.Fatal("watcher读取屏障未到达")
	}
	if state.onResponseReady() {
		t.Fatal("NoBody误判early-response")
	}
	if !state.onResponseDone() {
		t.Fatal("正常stop交接失败")
	}
	raw.mu.Lock()
	calls := append([]bool(nil), raw.calls...)
	raw.mu.Unlock()
	// watcher可能在Peek前看到stop直接退出；如调用deadline，必须先唤醒后恢复。
	if len(calls) != 1 && len(calls) != 2 {
		t.Fatal("读期限调用边界不符")
	}
	if !calls[len(calls)-1] {
		t.Fatal("join后未恢复读取")
	}
	state.onBodyEOF() // Done后迟到EOF不能重复Add或启动。
	state.mu.Lock()
	done := state.responseDone
	state.mu.Unlock()
	if !done {
		t.Fatal("Done事实丢失")
	}
}

func TestBlindEarlyResponseBodyReadingDoesNotUseReadDeadline(t *testing.T) {
	state, raw, client := blindStatePipe()
	defer client.Close()
	if !state.onResponseReady() {
		t.Fatal("BodyReading未标early-response")
	}
	raw.mu.Lock()
	count := len(raw.calls)
	raw.mu.Unlock()
	if count != 0 {
		t.Fatal("responseReady干扰活跃上传")
	}
	if state.onResponseDone() {
		t.Fatal("活跃正文Done后错误复用连接")
	}
	state.onBodyEOF()
	state.mu.Lock()
	started := state.watcherStarted
	state.mu.Unlock()
	raw.mu.Lock()
	count = len(raw.calls)
	raw.mu.Unlock()
	if started || count != 0 {
		t.Fatal("Done后迟到启动或干扰正文读期限")
	}
}

func TestBlindPrefixEOFAndSilentResponseCancel(t *testing.T) {
	state, _, client := blindStatePipe()
	state.onBodyEOF()
	if state.onResponseReady() {
		t.Fatal("NoBody误判early")
	}
	go func() { _, _ = io.WriteString(client, "GET /SECOND HTTP/1.1\r\n"); _ = client.Close() }()
	select {
	case <-state.conn.ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("prefix后的EOF未取消静默上游")
	}
	blindJoinFixture(t, state)
	if state.onResponseDone() {
		t.Fatal("EOF后仍可复用")
	}
}

func TestBlindPrefixBudgetDoesNotChangeHeaderBudget(t *testing.T) {
	for _, length := range []int{blindHeaderBytes, blindHeaderBytes + 1} {
		state, _, client := blindStatePipe()
		state.onBodyEOF()
		written := make(chan struct{})
		go func() { _, _ = io.WriteString(client, strings.Repeat("P", length)); close(written) }()
		select {
		case <-written:
		case <-time.After(time.Second):
			t.Fatal("prefix fixture未写完")
		}
		if length == blindHeaderBytes+1 {
			select {
			case <-state.conn.ctx.Done():
			case <-time.After(time.Second):
				t.Fatal("超prefix预算未拒绝")
			}
			blindJoinFixture(t, state)
		} else {
			if !state.onResponseDone() {
				t.Fatal("合法prefix被拒绝")
			}
		}
		_ = client.Close()
		_ = state.conn.Close()
	}
	for _, length := range []int{blindHeaderBytes, blindHeaderBytes + 1} {
		header := "GET / HTTP/1.1\r\nX: " + strings.Repeat("A", length-len("GET / HTTP/1.1\r\nX: \r\n\r\n")) + "\r\n\r\n"
		err := blindReadHeader(bufio.NewReaderSize(strings.NewReader(header), blindHeaderBytes+1))
		if (err == nil) != (length == blindHeaderBytes) {
			t.Fatal("header终点预算错误")
		}
	}
}

func TestBlindDeadlineFailureAndOwnerCloseRejectLateAdmission(t *testing.T) {
	for _, failWake := range []bool{true, false} {
		state, raw, client := blindStatePipe()
		raw.failWake = failWake
		raw.failRestore = !failWake
		state.onBodyEOF()
		select {
		case <-raw.readStarted:
		case <-time.After(time.Second):
			t.Fatal("watcher读取屏障未到达")
		}
		if state.onResponseDone() {
			t.Fatal("deadline失败误报可复用")
		}
		blindJoinFixture(t, state)
		_ = client.Close()
	}
	state, _, client := blindStatePipe()
	_ = state.conn.Close()
	state.onBodyEOF()
	state.onResponseReady()
	_ = state.onResponseDone()
	state.mu.Lock()
	started := state.watcherStarted
	state.mu.Unlock()
	if started {
		t.Fatal("OwnerClose后迟到Add")
	}
	_ = client.Close()
}

func TestBlindTwoPipelineRequestsOrdered(t *testing.T) {
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		defer c.Close()
		reader := bufio.NewReader(c)
		for {
			request, err := H.ReadRequest(reader)
			if err != nil {
				return
			}
			body := "1"
			if request.URL.Path == "/second" {
				body = "2"
			}
			_, _ = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n"+body)
		}
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	defer func() {
		if owner.Close() != nil {
			t.Error("pipeline退出不足")
		}
	}()
	_, _ = io.WriteString(client, "GET http://fixture.invalid/first HTTP/1.1\r\nHost: fixture.invalid\r\n\r\nGET http://fixture.invalid/second HTTP/1.1\r\nHost: fixture.invalid\r\nConnection: close\r\n\r\n")
	reader := bufio.NewReader(client)
	for _, expected := range []string{"1", "2"} {
		response, err := H.ReadResponse(reader, nil)
		if err != nil {
			t.Fatal("pipeline响应读取失败")
		}
		body, err := io.ReadAll(response.Body)
		_ = response.Body.Close()
		if err != nil || string(body) != expected {
			t.Fatal("pipeline顺序或交接错误")
		}
	}
}

func TestBlindStopConcurrentWithRealEOFAndLateBodyEvents(t *testing.T) {
	state, raw, client := blindStatePipe()
	state.onBodyEOF()
	select {
	case <-raw.readStarted:
	case <-time.After(time.Second):
		t.Fatal("watcher未进入读取")
	}
	gate := make(chan struct{})
	finished := make(chan bool, 1)
	go func() { <-gate; _ = client.Close() }()
	go func() { <-gate; finished <- state.onResponseDone() }()
	close(gate)
	select {
	case <-finished:
	case <-time.After(2 * time.Second):
		t.Fatal("stop与EOF交错未收束")
	}
	blindJoinFixture(t, state)
	state.onBodyEOF()
	state.onResponseReady()
	state.mu.Lock()
	admission, done := state.admission, state.responseDone
	state.mu.Unlock()
	if admission || !done {
		t.Fatal("迟到事件重新开放入场")
	}
	_ = state.conn.Close()
}

func TestBlindEarlyResponseLargeUploadStreaming(t *testing.T) {
	const length = 17 * 1024 * 1024
	completed := make(chan bool, 1)
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		defer c.Close()
		request, err := H.ReadRequest(bufio.NewReader(c))
		if err != nil {
			completed <- false
			return
		}
		// 上游先发响应头，正文保持活跃；最后一个响应字节在上传完成后写出。
		_, _ = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n")
		n, err := io.Copy(io.Discard, request.Body)
		completed <- n == length && err == nil
		_, _ = io.WriteString(c, "Z")
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	defer client.Close()
	defer func() {
		if owner.Close() != nil {
			t.Error("early-response退出不足")
		}
	}()
	_, _ = io.WriteString(client, "POST http://fixture.invalid/large HTTP/1.1\r\nHost: fixture.invalid\r\nContent-Length: 17825792\r\n\r\n")
	block := []byte(strings.Repeat("x", 64*1024))
	for written := 0; written < length; written += len(block) {
		if _, err := client.Write(block); err != nil {
			t.Fatal("early-response截断活跃上传")
		}
	}
	response, err := H.ReadResponse(bufio.NewReader(client), nil)
	if err != nil {
		t.Fatal("early-response响应失败")
	}
	body, err := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if err != nil || string(body) != "Z" || !<-completed {
		t.Fatal("大正文与响应未完整流式完成")
	}
}

func TestBlindSilentResponseBodyClientEOFCancels(t *testing.T) {
	exited := make(chan struct{})
	owner, err := NewCredentialBlindLoopback(blindFixtureTunnel{tcp: func(c net.Conn, m *C.Metadata) {
		defer close(exited)
		defer c.Close()
		if _, err := H.ReadRequest(bufio.NewReader(c)); err != nil {
			return
		}
		_, _ = io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n")
		_, _ = io.Copy(io.Discard, c) // 响应Body静默，客户端关闭须由watcher取消。
	}})
	if err != nil {
		t.Fatal("入口fixture创建失败")
	}
	client := blindDial(t, owner)
	_, _ = io.WriteString(client, "GET http://fixture.invalid/silent HTTP/1.1\r\nHost: fixture.invalid\r\n\r\n")
	if _, err := H.ReadResponse(bufio.NewReader(client), nil); err != nil {
		t.Fatal("响应头未到达")
	}
	_ = client.Close()
	select {
	case <-exited:
	case <-time.After(time.Second):
		t.Fatal("响应流静默期间EOF未取消")
	}
	if owner.Close() != nil {
		t.Fatal("响应EOF退出不足")
	}
}
