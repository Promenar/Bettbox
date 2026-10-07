package http

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	H "github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/inbound"
	N "github.com/metacubex/mihomo/common/net"
	C "github.com/metacubex/mihomo/constant"
)

// 专用构造器的固定资源预算，订阅不可设置。
const blindConnections = 32
const blindHeaderBytes = 32 * 1024
const blindHeaderTime = 15 * time.Second

var errBlindStopped = errors.New("专用入口停止证据不足")

// CredentialBlindListener只证明自身socket生命周期，不提供SC/IPC能力认证。
type CredentialBlindListener struct {
	listener     net.Listener
	tunnel       C.Tunnel
	mu           sync.Mutex
	closed       bool
	owned        map[*blindConn]struct{}
	acceptedDone chan struct{}
	handlers     sync.WaitGroup
	handlersDone chan struct{}
	routes       sync.WaitGroup
	watchers     sync.WaitGroup
	pipes        map[net.Conn]struct{}
}

type blindConn struct {
	net.Conn
	owner    *CredentialBlindListener
	once     sync.Once
	closeErr error
	ctx      context.Context
	cancel   context.CancelFunc
	request  *blindRequestState
}

func (c *blindConn) Close() error {
	c.once.Do(func() {
		c.owner.mu.Lock()
		request := c.request
		c.owner.mu.Unlock()
		if request != nil {
			request.closeAdmission()
		}
		c.cancel()
		c.closeErr = c.Conn.Close()
		c.owner.mu.Lock()
		if c.closeErr == nil {
			delete(c.owner.owned, c)
		}
		c.owner.mu.Unlock()
	})
	return c.closeErr
}

// NewCredentialBlindLoopback没有地址、认证或订阅参数；仅供将来可信宿主调用。
func NewCredentialBlindLoopback(tunnel C.Tunnel) (*CredentialBlindListener, error) {
	if tunnel == nil {
		return nil, errors.New("专用入口路由不可用")
	}
	socket, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("专用入口绑定失败")
	}
	owner := &CredentialBlindListener{listener: socket, tunnel: tunnel,
		owned: make(map[*blindConn]struct{}), pipes: make(map[net.Conn]struct{}), acceptedDone: make(chan struct{}), handlersDone: make(chan struct{})}
	go owner.accept()
	return owner, nil
}

func (l *CredentialBlindListener) Address() string { return l.listener.Addr().String() }

func (l *CredentialBlindListener) accept() {
	defer func() {
		// 即使Accept意外退出也关闭入场，避免迟到EOF在最终Wait后Add。
		l.mu.Lock()
		l.closed = true
		l.mu.Unlock()
		close(l.acceptedDone)
		go func() { l.handlers.Wait(); l.routes.Wait(); l.watchers.Wait(); close(l.handlersDone) }()
	}()
	for {
		raw, err := l.listener.Accept()
		if err != nil {
			return
		}
		l.mu.Lock()
		if l.closed || len(l.owned) >= blindConnections {
			l.mu.Unlock()
			_ = raw.Close() // 并发超限仅关闭该连接，不输出输入或身份。
			continue
		}
		ctx, cancel := context.WithCancel(context.Background())
		c := &blindConn{Conn: raw, owner: l, ctx: ctx, cancel: cancel}
		l.owned[c] = struct{}{}
		l.handlers.Add(1)
		l.mu.Unlock()
		go func() {
			defer l.handlers.Done()
			// CONNECT阻塞路由；即使路由返回仍由owned集合保留未关闭socket。
			handleCredentialBlind(c, blindOwnedTunnel{owner: l, delegate: l.tunnel})
		}()
	}
}

func (l *CredentialBlindListener) Close() error {
	l.mu.Lock()
	l.closed = true
	connections := make([]*blindConn, 0, len(l.owned))
	for c := range l.owned {
		connections = append(connections, c)
	}
	pipes := make([]net.Conn, 0, len(l.pipes))
	for c := range l.pipes {
		pipes = append(pipes, c)
	}
	l.mu.Unlock()
	socketErr := l.listener.Close()
	socketFailed := socketErr != nil && !errors.Is(socketErr, net.ErrClosed)
	for _, c := range connections {
		_ = c.Close()
	}
	for _, c := range pipes {
		_ = c.Close()
	}
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	select {
	case <-l.acceptedDone:
	case <-deadline.C:
		return errBlindStopped
	}
	// accept已退出，Wait期间不可能再Add；只创建一个有界收束等待者。
	select {
	case <-l.handlersDone:
	case <-deadline.C:
		return errBlindStopped
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if socketFailed || len(l.owned) != 0 || len(l.pipes) != 0 {
		return errBlindStopped
	}
	return nil
}

// 所有内部路由在启动goroutine前登记；Close关闭pipe仍必须等待真实调用退出。
// 64个route包含有限idle HTTP连接；资源上限固定，超限拒绝。
type blindOwnedTunnel struct {
	owner    *CredentialBlindListener
	delegate C.Tunnel
}

func (t blindOwnedTunnel) HandleUDPPacket(packet C.UDPPacket, metadata *C.Metadata) {
	t.delegate.HandleUDPPacket(packet, metadata)
}
func (t blindOwnedTunnel) NatTable() C.NatTable { return t.delegate.NatTable() }
func (t blindOwnedTunnel) register(c net.Conn) bool {
	t.owner.mu.Lock()
	if t.owner.closed || len(t.owner.pipes) >= 64 {
		t.owner.mu.Unlock()
		_ = c.Close()
		return false
	}
	if t.owner.pipes == nil {
		t.owner.pipes = make(map[net.Conn]struct{})
	}
	t.owner.pipes[c] = struct{}{}
	t.owner.routes.Add(1)
	t.owner.mu.Unlock()
	return true
}
func (t blindOwnedTunnel) finish(c net.Conn, closePipe bool) {
	if closePipe {
		_ = c.Close()
	}
	t.owner.mu.Lock()
	delete(t.owner.pipes, c)
	t.owner.mu.Unlock()
	t.owner.routes.Done()
}
func (t blindOwnedTunnel) HandleTCPConn(c net.Conn, metadata *C.Metadata) {
	if !t.register(c) {
		return
	}
	defer t.finish(c, false) // CONNECT移交的accepted socket由owned集合继续管理。
	t.delegate.HandleTCPConn(c, metadata)
}
func (t blindOwnedTunnel) startOwnedTCPConn(c net.Conn, metadata *C.Metadata) {
	if !t.register(c) {
		return
	}
	go func() { defer t.finish(c, true); t.delegate.HandleTCPConn(c, metadata) }()
}

// 专用包装器在启动内部路由前同步登记。
func startHTTPRoute(tunnel C.Tunnel, c net.Conn, metadata *C.Metadata) {
	if owned, ok := tunnel.(blindOwnedTunnel); ok {
		owned.startOwnedTCPConn(c, metadata)
		return
	}
	go tunnel.HandleTCPConn(c, metadata) // 原入口行为不变。
}

func (c *blindConn) startWatcher(watch func()) bool {
	c.owner.mu.Lock()
	if c.owner.closed || c.ctx.Err() != nil {
		c.owner.mu.Unlock()
		return false
	}
	c.owner.watchers.Add(1)
	c.owner.mu.Unlock()
	go func() { defer c.owner.watchers.Done(); watch() }()
	return true
}

// 只查看字段名；不得解码、记录或传播代理认证值。
func blindAuthField(name string) bool {
	return strings.EqualFold(name, "Proxy-Authorization") ||
		strings.EqualFold(name, "Proxy-Authenticate") ||
		strings.EqualFold(name, "Proxy-Authentication-Info")
}

func blindOutput(input *H.Request) (*H.Request, bool) {
	for key := range input.Header {
		if blindAuthField(key) {
			delete(input.Header, key)
		}
	}
	for key := range input.Trailer {
		if blindAuthField(key) {
			return nil, false
		}
	}
	if input.Method == H.MethodConnect &&
		(len(input.Trailer) != 0 || len(input.TransferEncoding) != 0 || input.ContentLength > 0) {
		return nil, false
	}
	output := input.Clone(input.Context())
	output.Header = input.Header.Clone()
	output.Trailer = nil // EOF只能填充input.Trailer，输出不共享其map或指针。
	for key := range output.Header {
		if blindAuthField(key) || strings.EqualFold(key, "Trailer") {
			delete(output.Header, key)
		}
	}
	// 保留目标Authorization及正文；不调用authenticate或WithInUser。
	return output, true
}

func blindReadHeader(reader *bufio.Reader) error {
	for size := 1; size <= blindHeaderBytes; {
		value, err := reader.Peek(size)
		if err != nil {
			return errors.New("专用入口请求头拒绝")
		}
		available := reader.Buffered()
		value, _ = reader.Peek(available)
		if marker := bytes.Index(value, []byte("\r\n\r\n")); marker >= 0 {
			if marker+4 <= blindHeaderBytes {
				return nil
			}
			return errors.New("专用入口请求头预算耗尽")
		}
		size = available + 1
	}
	return errors.New("专用入口请求头预算耗尽")
}

func handleCredentialBlind(conn *blindConn, tunnel C.Tunnel) {
	reader := bufio.NewReaderSize(conn, blindHeaderBytes+1)
	additions := []inbound.Addition{inbound.WithInName("BETTBOX-SYSTEM-HTTP")}
	client := newClient(conn, tunnel, additions)
	defer client.CloseIdleConnections()
	for {
		if conn.SetDeadline(time.Now().Add(blindHeaderTime)) != nil {
			_ = conn.Close()
			return
		}
		headerErr := blindReadHeader(reader)
		if headerErr != nil {
			_ = conn.Close()
			return
		}
		input, err := ReadRequest(reader)
		if err != nil {
			_ = conn.Close()
			return
		}
		input.RemoteAddr = conn.RemoteAddr().String()
		output, accepted := blindOutput(input)
		if !accepted {
			response := responseWith(input, H.StatusBadRequest)
			response.Close = true
			_ = response.Write(conn)
			_ = conn.Close()
			return // 不排空拒绝正文，避免认证Trailer被主动读取。
		}
		if conn.SetDeadline(time.Time{}) != nil {
			_ = conn.Close()
			return
		} // 正文无绝对寿命。
		if input.Method == H.MethodConnect {
			_, err = io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
			if err != nil {
				_ = conn.Close()
				return
			}
			tunnel.HandleTCPConn(inbound.NewHTTPS(output, N.WarpConnWithBioReader(conn, reader), additions...))
			return // 移交后不解除owned；真正Close才解除。
		}
		output.RequestURI = ""
		if isUpgradeRequest(output) {
			// 取消时关闭内部pipe，停止等待必须覆盖实际handler。
			handleUpgradeBlindWithContext(conn.ctx, N.WarpConnWithBioReader(conn, reader), output, tunnel, additions...)
			return
		}
		removeHopByHopHeaders(output.Header)
		removeExtraHTTPHostPort(output)
		if output.URL.Scheme != "http" || output.URL.Host == "" {
			response := responseWith(input, H.StatusBadRequest)
			response.Close = true
			_ = response.Write(conn)
			_ = conn.Close()
			return
		}
		state := newBlindRequest(conn, reader)
		if output.Body == nil || output.Body == H.NoBody {
			state.onBodyEOF()
		} else {
			output.Body = &bodyWrapper{ReadCloser: output.Body, onHitEOF: state.onBodyEOF}
		}
		response, err := client.Do(output.WithContext(conn.ctx))
		earlyResponse := state.onResponseReady()
		if err != nil {
			response = responseWith(input, H.StatusBadGateway)
		}
		originalResponse := response
		response = new(H.Response)
		*response = *originalResponse
		response.Header = originalResponse.Header.Clone()
		removeHopByHopHeaders(response.Header)
		for key := range response.Header {
			if blindAuthField(key) || strings.EqualFold(key, "Trailer") {
				delete(response.Header, key)
			}
		}
		// 输入响应EOF只填充originalResponse，输出Trailer保持nil。
		response.Trailer = nil
		response.Close = input.Close || response.Close || earlyResponse
		err = response.Write(conn)
		if response.Body != nil {
			_ = response.Body.Close()
		}
		reusable := state.onResponseDone()
		if err != nil || response.Close || !reusable {
			_ = conn.Close()
			return
		}
	}
}
