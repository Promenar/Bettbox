//go:build !cgo

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"sync"
	"testing"
	"time"
)

// 只使用公开内存及io.Pipe，不启动子进程、listener或目标网络。
type fixtureStream struct {
	input      *io.PipeReader
	output     *io.PipeWriter
	closeOnce  sync.Once
	closed     chan struct{}
	writes     chan struct{}
	afterRead  func(int)
	afterWrite func()
}

func (f *fixtureStream) Read(p []byte) (int, error) {
	n, err := f.input.Read(p)
	if f.afterRead != nil {
		f.afterRead(n)
	}
	return n, err
}
func (f *fixtureStream) Write(p []byte) (int, error) {
	select {
	case f.writes <- struct{}{}:
	default:
	}
	n, err := f.output.Write(p)
	if err == nil && f.afterWrite != nil {
		f.afterWrite()
	}
	return n, err
}
func (f *fixtureStream) Close() error {
	f.closeOnce.Do(func() { _ = f.input.Close(); _ = f.output.Close(); close(f.closed) })
	return nil
}

type fixtureClient struct {
	input   *io.PipeWriter
	output  *io.PipeReader
	stream  *fixtureStream
	result  chan error
	session *ownedSession
}

func fixture(t *testing.T, dispatch func(*Action, ActionResult)) *fixtureClient {
	return fixtureBudget(t, dispatch, 500*time.Millisecond)
}
func fixtureBudget(t *testing.T, dispatch func(*Action, ActionResult), budget time.Duration) *fixtureClient {
	return fixtureConfigured(t, dispatch, budget, nil)
}
func fixtureConfigured(t *testing.T, dispatch func(*Action, ActionResult), budget time.Duration, configure func(*ownedSession, *fixtureStream)) *fixtureClient {
	t.Helper()
	inputR, inputW := io.Pipe()
	outputR, outputW := io.Pipe()
	stream := &fixtureStream{inputR, outputW, sync.Once{}, make(chan struct{}), make(chan struct{}, 8), nil, nil}
	session := newOwnedSession(stream, dispatch)
	session.budget = budget
	if configure != nil {
		configure(session, stream)
	}
	client := &fixtureClient{inputW, outputR, stream, make(chan error, 1), session}
	go func() { client.result <- session.serve() }()
	t.Cleanup(func() { session.stop(); _ = inputW.Close(); _ = outputR.Close(); _ = stream.Close() })
	return client
}
func sendFixture(t *testing.T, c *fixtureClient, payload string) {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- writeFrame(c.input, []byte(payload)) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("fixture写入失败")
		}
	case <-time.After(time.Second):
		t.Fatal("fixture写入未退出")
	}
}
func receiveFixture(t *testing.T, c *fixtureClient) []byte {
	t.Helper()
	result := make(chan ownedRead, 1)
	go func() { value, err := ownedReadFrame(c.output, ownedBusinessLimit); result <- ownedRead{value, err} }()
	select {
	case value := <-result:
		if value.err != nil {
			t.Fatal("fixture响应拒绝")
		}
		return value.payload
	case <-time.After(time.Second):
		t.Fatal("fixture响应未退出")
	}
	return nil
}
func finishFixture(t *testing.T, c *fixtureClient, failure bool) {
	t.Helper()
	select {
	case err := <-c.result:
		if (err != nil) != failure {
			t.Fatal("会话结论不符")
		}
	case <-time.After(time.Second):
		t.Fatal("会话入口未返回")
	}
}
func helloFixture(t *testing.T, c *fixtureClient) {
	sendFixture(t, c, `{"type":"hello","protocol":1,"generation":7}`)
	var ack struct {
		Type       string
		Protocol   int
		Generation int64
	}
	if json.Unmarshal(receiveFixture(t, c), &ack) != nil || ack.Type != "ack" || ack.Protocol != 1 || ack.Generation != 7 {
		t.Fatal("握手不符")
	}
}
func TestOwnedStrictFirstFrame(t *testing.T) {
	values := []string{
		`{"protocol":1,"generation":7,"action":{"id":"a","method":"m","data":null}}`,
		`{"type":"hello","protocol":1,"protocol":1,"generation":7}`,
		`{"type":"hello","protocol":1,"generation":7,"extra":true}`,
		`{"type":"hello","protocol":1,"generation":0}`,
		`{"type":"hello","protocol":1,"generation":-1}`,
		`{"type":"hello","protocol":1,"generation":7.0}`,
		`{"type":"hello","protocol":1,"generation":7} {}`,
		`日志污染`,
	}
	for _, value := range values {
		t.Run(value, func(t *testing.T) {
			called := make(chan struct{}, 1)
			c := fixture(t, func(*Action, ActionResult) { called <- struct{}{} })
			sendFixture(t, c, value)
			finishFixture(t, c, true)
			select {
			case <-called:
				t.Fatal("握手前业务准入")
			default:
			}
		})
	}
}
func TestOwnedGenerationAndResultBinding(t *testing.T) {
	c := fixture(t, func(_ *Action, result ActionResult) { result.success("public-fixture") })
	helloFixture(t, c)
	sendFixture(t, c, `{"protocol":1,"generation":7,"action":{"id":"a","method":"m","data":null}}`)
	fields, err := ownedObject(receiveFixture(t, c), "protocol", "generation", "result")
	if err != nil {
		t.Fatal("结果envelope不符")
	}
	generation, err := ownedGeneration(fields)
	if err != nil || generation != 7 {
		t.Fatal("结果代次不符")
	}
	var result ActionResult
	if json.Unmarshal(fields["result"], &result) != nil || result.Id != "a" || result.Code != 0 || result.Data != "public-fixture" {
		t.Fatal("业务结果不符")
	}
	_ = c.input.Close()
	finishFixture(t, c, false)
}
func TestOwnedWrongGenerationNeverDispatches(t *testing.T) {
	called := make(chan struct{}, 1)
	c := fixture(t, func(*Action, ActionResult) { called <- struct{}{} })
	helloFixture(t, c)
	sendFixture(t, c, `{"protocol":1,"generation":8,"action":{"id":"a","method":"m","data":null}}`)
	finishFixture(t, c, true)
	select {
	case <-called:
		t.Fatal("错误代次准入")
	default:
	}
}
func TestOwnedEOFReturnsWithoutWaitingAdmittedTask(t *testing.T) {
	entered, release, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	c := fixture(t, func(_ *Action, result ActionResult) {
		close(entered)
		<-release
		result.success("late-public-fixture")
		close(finished)
	})
	helloFixture(t, c)
	sendFixture(t, c, `{"protocol":1,"generation":7,"action":{"id":"a","method":"m","data":null}}`)
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("未准入fixture")
	}
	_ = c.input.Close()
	finishFixture(t, c, false)
	close(release)
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("迟到发送未丢弃")
	}
	if _, err := c.output.Read(make([]byte, 1)); err != io.EOF {
		t.Fatal("关闭后产生业务结果")
	}
}
func TestOwnedBlockedWriterStopDoesNotWaitWriterMutex(t *testing.T) {
	entered := make(chan struct{})
	c := fixture(t, func(_ *Action, result ActionResult) { close(entered); result.success("blocked-public-fixture") })
	helloFixture(t, c)
	<-c.stream.writes // ACK已完成，后续屏障只能来自业务writer。
	sendFixture(t, c, `{"protocol":1,"generation":7,"action":{"id":"a","method":"m","data":null}}`)
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("未准入fixture")
	}
	select {
	case <-c.stream.writes:
	case <-time.After(time.Second):
		t.Fatal("writer未进入阻塞写入")
	}
	// 不读取业务输出，io.Pipe写入阻塞；入口仍须撤销并返回。
	c.session.stop()
	finishFixture(t, c, true)
}
func TestOwnedSendFailureEndsEntry(t *testing.T) {
	c := fixture(t, func(_ *Action, result ActionResult) { result.success("public-fixture") })
	helloFixture(t, c)
	_ = c.output.Close()
	sendFixture(t, c, `{"protocol":1,"generation":7,"action":{"id":"a","method":"m","data":null}}`)
	finishFixture(t, c, true)
}
func TestOwnedNoResultsBeforeHandshake(t *testing.T) {
	c := fixture(t, func(*Action, ActionResult) {})
	c.session.sendResult([]byte(`{"id":"unexpected"}`))
	helloFixture(t, c) // 唯一首帧必须是ACK。
	_ = c.input.Close()
	finishFixture(t, c, false)
}
func TestOwnedHandshakeBudget(t *testing.T) {
	c := fixtureBudget(t, func(*Action, ActionResult) { t.Error("不应dispatch") }, 10*time.Millisecond)
	finishFixture(t, c, true)
}
func TestOwnedHandshakeLengthCheckedBeforeAllocation(t *testing.T) {
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], ownedHandshakeLimit+1)
	if _, err := ownedReadFrame(bytes.NewReader(header[:]), ownedHandshakeLimit); err == nil {
		t.Fatal("超限未拒绝")
	}
}
func TestOwnedTruncatedFrameRejected(t *testing.T) {
	c := fixture(t, func(*Action, ActionResult) {})
	helloFixture(t, c)
	_, _ = c.input.Write([]byte{4, 0, 0, 0, '{'})
	_ = c.input.Close()
	finishFixture(t, c, true)
}

type fragmentWriter struct {
	bytes.Buffer
	count int
	zero  bool
}

func (w *fragmentWriter) Write(p []byte) (int, error) {
	w.count++
	if w.zero {
		return 0, nil
	}
	if len(p) > 3 {
		p = p[:3]
	}
	return w.Buffer.Write(p)
}
func TestFrameWritesAllFragments(t *testing.T) {
	writer := &fragmentWriter{}
	if writeFrame(writer, []byte("public-fixture")) != nil || writer.count < 2 {
		t.Fatal("未完整写入")
	}
	value, err := readFrame(bytes.NewReader(writer.Bytes()))
	if err != nil || string(value) != "public-fixture" {
		t.Fatal("旧帧语义变化")
	}
}
func TestFrameNoProgressRejected(t *testing.T) {
	if writeFrame(&fragmentWriter{zero: true}, []byte("fixture")) != io.ErrNoProgress {
		t.Fatal("无进展未拒绝")
	}
}
func TestLegacyResultJSONUnchanged(t *testing.T) {
	result := ActionResult{Id: "a", Method: "m", Data: "fixture", Code: 0, ownedSend: func([]byte) { t.Error("Json不能发送") }}
	raw, err := result.Json()
	if err != nil || bytes.Contains(raw, []byte("owned")) || bytes.Contains(raw, []byte("generation")) {
		t.Fatal("旧结果协议变化")
	}
}

type fixtureBlockingClose struct {
	io.ReadWriteCloser
	entered chan struct{}
	release chan struct{}
}

func (f *fixtureBlockingClose) Close() error {
	close(f.entered)
	<-f.release
	return f.ReadWriteCloser.Close()
}
func TestOwnedEntryReturnsEvenWhenCloseHasNotCompleted(t *testing.T) {
	inputR, inputW := io.Pipe()
	outputR, outputW := io.Pipe()
	stream := &fixtureStream{inputR, outputW, sync.Once{}, make(chan struct{}), make(chan struct{}, 8), nil, nil}
	blocked := &fixtureBlockingClose{stream, make(chan struct{}), make(chan struct{})}
	session := newOwnedSession(blocked, func(*Action, ActionResult) {})
	client := &fixtureClient{inputW, outputR, stream, make(chan error, 1), session}
	t.Cleanup(func() { _ = inputW.Close(); _ = outputR.Close(); _ = stream.Close() })
	go func() { client.result <- session.serve() }()
	helloFixture(t, client)
	_ = inputW.Close()
	finishFixture(t, client, false)
	select {
	case <-blocked.entered:
	case <-time.After(time.Second):
		t.Fatal("closer未启动")
	}
	select {
	case <-stream.closed:
		t.Fatal("不能伪报Close已完成")
	default:
	}
	select {
	case <-session.ctx.Done():
	default:
		t.Fatal("会话context未取消")
	}
	close(blocked.release)
	select {
	case <-stream.closed:
	case <-time.After(time.Second):
		t.Fatal("fixture释放后未关闭")
	}
}
func TestOwnedBusinessLengthBound(t *testing.T) {
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], ownedBusinessLimit+1)
	if _, err := ownedReadFrame(bytes.NewReader(header[:]), ownedBusinessLimit); err == nil {
		t.Fatal("业务帧预算未限制")
	}
}

func TestOwnedSerializationFailureEndsEntry(t *testing.T) {
	c := fixture(t, func(_ *Action, result ActionResult) { result.success(make(chan int)) })
	helloFixture(t, c)
	sendFixture(t, c, `{"protocol":1,"generation":7,"action":{"id":"a","method":"m","data":null}}`)
	finishFixture(t, c, true)
}

// 受控时钟保留基准time.Now的单调分量；所有改变由显式I/O屏障触发。
type fixtureClock struct {
	mu                 sync.Mutex
	current            time.Time
	advanceAfterSample bool
	target             time.Time
}

func (c *fixtureClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	value := c.current
	if c.advanceAfterSample {
		c.current = c.target
		c.advanceAfterSample = false
	}
	return value
}
func (c *fixtureClock) set(value time.Time) { c.mu.Lock(); c.current = value; c.mu.Unlock() }
func (c *fixtureClock) arm(value time.Time) {
	c.mu.Lock()
	c.target = value
	c.advanceAfterSample = true
	c.mu.Unlock()
}
func assertNoFixtureDispatch(t *testing.T, called <-chan struct{}) {
	t.Helper()
	select {
	case <-called:
		t.Fatal("截止后业务被准入")
	default:
	}
}
func TestOwnedDeadlineRejectsSuccessfulReadAfterExpiry(t *testing.T) {
	clock := &fixtureClock{current: time.Now()}
	deadline := clock.now().Add(ownedHandshakeBudget)
	called := make(chan struct{}, 1)
	hello := `{"type":"hello","protocol":1,"generation":7}`
	c := fixtureConfigured(t, func(*Action, ActionResult) { called <- struct{}{} }, ownedHandshakeBudget, func(s *ownedSession, f *fixtureStream) {
		s.now = clock.now
		consumed := 0
		f.afterRead = func(n int) {
			consumed += n
			if consumed == 4+len(hello) {
				clock.set(deadline)
			}
		}
	})
	output := make(chan ownedRead, 1)
	go func() { value, err := ownedReadFrame(c.output, ownedHandshakeLimit); output <- ownedRead{value, err} }()
	sendFixture(t, c, hello)
	finishFixture(t, c, true)
	select {
	case value := <-output:
		if value.err == nil {
			t.Fatal("截止后读取仍发送ACK")
		}
	case <-time.After(time.Second):
		t.Fatal("拒绝后控制流未关闭")
	}
	assertNoFixtureDispatch(t, called)
}
func TestOwnedDeadlineRejectsACKCompletionAfterExpiry(t *testing.T) {
	clock := &fixtureClock{current: time.Now()}
	deadline := clock.now().Add(ownedHandshakeBudget)
	ackWritten, release := make(chan struct{}), make(chan struct{})
	called := make(chan struct{}, 1)
	c := fixtureConfigured(t, func(*Action, ActionResult) { called <- struct{}{} }, ownedHandshakeBudget, func(s *ownedSession, f *fixtureStream) {
		s.now = clock.now
		f.afterWrite = func() { close(ackWritten); <-release }
	})
	sendFixture(t, c, `{"type":"hello","protocol":1,"generation":7}`)
	_ = receiveFixture(t, c)
	select {
	case <-ackWritten:
	case <-time.After(time.Second):
		t.Fatal("ACK完成屏障未到达")
	}
	queued := make(chan error, 1)
	go func() {
		queued <- writeFrame(c.input, []byte(`{"protocol":1,"generation":7,"action":{"id":"a","method":"m","data":null}}`))
	}()
	clock.set(deadline) // 精确等于截止点也不允许成功。
	close(release)
	finishFixture(t, c, true)
	select {
	case err := <-queued:
		if err == nil {
			t.Fatal("截止后继续读取业务帧")
		}
	case <-time.After(time.Second):
		t.Fatal("排队业务写入未取消")
	}
	assertNoFixtureDispatch(t, called)
}
func TestOwnedDeadlineCheckedAgainAtReadyCommit(t *testing.T) {
	clock := &fixtureClock{current: time.Now()}
	deadline := clock.now().Add(ownedHandshakeBudget)
	called := make(chan struct{}, 1)
	c := fixtureConfigured(t, func(*Action, ActionResult) { called <- struct{}{} }, ownedHandshakeBudget, func(s *ownedSession, f *fixtureStream) {
		s.now = clock.now
		// ACK完成检查获得截止前样本，锁内ready提交获得截止点样本。
		f.afterWrite = func() { clock.arm(deadline) }
	})
	sendFixture(t, c, `{"type":"hello","protocol":1,"generation":7}`)
	_ = receiveFixture(t, c)
	finishFixture(t, c, true)
	c.session.mu.Lock()
	ready := c.session.ready
	c.session.mu.Unlock()
	if ready {
		t.Fatal("截止后提交ready")
	}
	assertNoFixtureDispatch(t, called)
}

func TestOwnedDeadlineRejectsParsingAfterReadSample(t *testing.T) {
	clock := &fixtureClock{current: time.Now()}
	deadline := clock.now().Add(ownedHandshakeBudget)
	called := make(chan struct{}, 1)
	hello := `{"type":"hello","protocol":1,"generation":7}`
	c := fixtureConfigured(t, func(*Action, ActionResult) { called <- struct{}{} }, ownedHandshakeBudget, func(s *ownedSession, f *fixtureStream) {
		s.now = clock.now
		consumed := 0
		// 读取成功检查取得截止前样本，解析结束检查取得截止点样本。
		f.afterRead = func(n int) {
			consumed += n
			if consumed == 4+len(hello) {
				clock.arm(deadline)
			}
		}
	})
	output := make(chan ownedRead, 1)
	go func() { value, err := ownedReadFrame(c.output, ownedHandshakeLimit); output <- ownedRead{value, err} }()
	sendFixture(t, c, hello)
	finishFixture(t, c, true)
	select {
	case value := <-output:
		if value.err == nil {
			t.Fatal("过期解析仍发送ACK")
		}
	case <-time.After(time.Second):
		t.Fatal("拒绝后控制流未关闭")
	}
	assertNoFixtureDispatch(t, called)
}
