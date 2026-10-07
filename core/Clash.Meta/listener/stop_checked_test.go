package listener

import (
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	HTTP "github.com/metacubex/mihomo/listener/http"
	LT "github.com/metacubex/mihomo/listener/tunnel"
)

type checkedFixtureConfig struct{}

func (checkedFixtureConfig) Name() string               { return "虚构监听" }
func (checkedFixtureConfig) Equal(C.InboundConfig) bool { return false }

type checkedFixtureInbound struct {
	closeCalls atomic.Int32
	fail       bool
	panicClose bool
	entered    chan struct{}
	release    chan struct{}
}

func (*checkedFixtureInbound) Name() string            { return "虚构监听" }
func (*checkedFixtureInbound) Listen(C.Tunnel) error   { return nil }
func (*checkedFixtureInbound) Address() string         { return "" }
func (*checkedFixtureInbound) RawAddress() string      { return "" }
func (*checkedFixtureInbound) Config() C.InboundConfig { return checkedFixtureConfig{} }
func (l *checkedFixtureInbound) Close() error {
	l.closeCalls.Add(1)
	if l.entered != nil {
		close(l.entered)
		<-l.release
	}
	if l.panicClose {
		panic("虚构底层异常不可进入日志")
	}
	if l.fail {
		return errors.New("虚构底层错误不可进入日志")
	}
	return nil
}

func TestCheckedInboundFailureRetainsAndContinues(t *testing.T) {
	failed := &checkedFixtureInbound{fail: true}
	good := &checkedFixtureInbound{}
	inboundListeners = map[string]C.InboundListener{"失败": failed, "成功": good, "相同对象": failed, "空": (*checkedFixtureInbound)(nil)}
	t.Cleanup(func() { inboundListeners = map[string]C.InboundListener{} })
	if err := StopListenerChecked(); err != errListenerCloseUnconfirmed {
		t.Fatal("失败必须返回固定关闭未确认")
	}
	if len(inboundListeners) != 2 || inboundListeners["失败"] != failed || inboundListeners["相同对象"] != failed {
		t.Fatal("失败对象必须保留且成功与空对象删除")
	}
	if failed.closeCalls.Load() != 1 || good.closeCalls.Load() != 1 {
		t.Fatal("单轮相同对象只关闭一次且尝试其它资源")
	}
	failed.fail = false
	if StopListenerChecked() != nil || len(inboundListeners) != 0 || failed.closeCalls.Load() != 2 {
		t.Fatal("后续显式关闭恢复必须确认真实结果")
	}
}

func TestCheckedClosePanicDoesNotLoseOtherResources(t *testing.T) {
	bad := &checkedFixtureInbound{panicClose: true}
	good := &checkedFixtureInbound{}
	inboundListeners = map[string]C.InboundListener{"失败": bad, "成功": good}
	t.Cleanup(func() { inboundListeners = map[string]C.InboundListener{} })
	if StopListenerChecked() != errListenerCloseUnconfirmed || inboundListeners["失败"] != bad || good.closeCalls.Load() != 1 {
		t.Fatal("固定失败必须保留归属且继续其它资源")
	}
}

func TestCheckedCloseUsesRealInboundRecreateMutex(t *testing.T) {
	blocked := &checkedFixtureInbound{entered: make(chan struct{}), release: make(chan struct{})}
	inboundListeners = map[string]C.InboundListener{"屏障": blocked}
	finished := make(chan error, 1)
	closeDone := make(chan struct{})
	var recreated chan struct{}
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(blocked.release) }) }
	// 首次等待前登记；失败路径也唤醒Close，不重复close屏障。
	t.Cleanup(func() {
		release()
		select {
		case <-closeDone:
		case <-time.After(time.Second):
			t.Error("关闭夹具清理未完成，不能声称goroutine已退出")
			return
		}
		if recreated != nil {
			select {
			case <-recreated:
			case <-time.After(time.Second):
				t.Error("重建夹具清理未完成，不能声称goroutine已退出")
				return
			}
		}
		inboundMux.Lock()
		inboundListeners = map[string]C.InboundListener{}
		inboundMux.Unlock()
	})
	go func() { defer close(closeDone); finished <- StopListenerChecked() }()
	select {
	case <-blocked.entered:
	case <-time.After(time.Second):
		t.Fatal("夹具未到关闭屏障")
	}
	if inboundMux.TryLock() {
		inboundMux.Unlock()
		t.Fatal("生产关闭必须持有实际重建锁")
	}
	recreated = make(chan struct{})
	go func() { PatchInboundListeners(map[string]C.InboundListener{}, nil, true); close(recreated) }()
	select {
	case <-recreated:
		t.Fatal("重建不能绕过正在关闭的槽位锁")
	default:
	}
	release()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal("夹具关闭失败")
		}
	case <-time.After(time.Second):
		t.Fatal("关闭夹具超时")
	}
	select {
	case <-recreated:
	case <-time.After(time.Second):
		t.Fatal("重建在锁释放后必须完成")
	}
	if len(inboundListeners) != 0 {
		t.Fatal("成功关闭归属应清空")
	}
}

// 构造成功才交给实际生产地图；保存底层真实socket以确认Close效果。
type checkedFixtureListenConfig struct {
	tcp net.Listener
	udp net.PacketConn
}

func (c *checkedFixtureListenConfig) Listen(ctx context.Context, network, address string) (net.Listener, error) {
	l, err := (&net.ListenConfig{}).Listen(ctx, network, address)
	if err == nil {
		c.tcp = l
	}
	return l, err
}
func (c *checkedFixtureListenConfig) ListenPacket(ctx context.Context, network, address string) (net.PacketConn, error) {
	p, err := (&net.ListenConfig{}).ListenPacket(ctx, network, address)
	if err == nil {
		c.udp = p
	}
	return p, err
}

func TestCheckedHTTPRealSocketClosed(t *testing.T) {
	l, err := HTTP.New("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal("公开loopback HTTP夹具构造失败")
	}
	httpMux.Lock()
	httpListener = l
	httpMux.Unlock()
	t.Cleanup(func() {
		httpMux.Lock()
		if httpListener == l {
			_ = l.Close()
			httpListener = nil
		}
		httpMux.Unlock()
	})
	address := l.Address()
	if StopListenerChecked() != nil || httpListener != nil {
		t.Fatal("真实HTTP socket关闭必须成功清归属")
	}
	c, err := net.DialTimeout("tcp4", address, time.Second)
	if c != nil {
		_ = c.Close()
	}
	if err == nil {
		t.Fatal("已关闭HTTP socket必须拒绝新dial")
	}
}

func TestCheckedTunnelMapsRealSocketsClosed(t *testing.T) {
	cfg := &checkedFixtureListenConfig{}
	tcp, err := LT.New("127.0.0.1:0", "127.0.0.1:9", "", cfg, nil)
	if err != nil {
		t.Fatal("公开loopback TCP tunnel夹具构造失败")
	}
	udp, err := LT.NewUDP("127.0.0.1:0", "127.0.0.1:9", "", cfg, nil)
	if err != nil {
		_ = tcp.Close()
		t.Fatal("公开loopback UDP tunnel夹具构造失败")
	}
	tunnelMux.Lock()
	tunnelTCPListeners["虚构TCP"] = tcp
	tunnelUDPListeners["虚构UDP"] = udp
	tunnelMux.Unlock()
	t.Cleanup(func() {
		tunnelMux.Lock()
		if tunnelTCPListeners["虚构TCP"] == tcp {
			_ = tcp.Close()
			delete(tunnelTCPListeners, "虚构TCP")
		}
		if tunnelUDPListeners["虚构UDP"] == udp {
			_ = udp.Close()
			delete(tunnelUDPListeners, "虚构UDP")
		}
		tunnelMux.Unlock()
	})
	if StopListenerChecked() != nil || len(tunnelTCPListeners) != 0 || len(tunnelUDPListeners) != 0 {
		t.Fatal("两个真实tunnel maps必须成功关闭清空")
	}
	if _, err := cfg.tcp.Accept(); !errors.Is(err, net.ErrClosed) {
		t.Fatal("底层TCP socket必须实际关闭")
	}
	if _, err := cfg.udp.WriteTo([]byte{0}, cfg.udp.LocalAddr()); !errors.Is(err, net.ErrClosed) {
		t.Fatal("底层UDP socket必须实际关闭且不发送")
	}
	c, err := net.DialTimeout("tcp4", tcp.Address(), time.Second)
	if c != nil {
		_ = c.Close()
	}
	if err == nil {
		t.Fatal("tunnel TCP关闭后必须拒绝dial")
	}
}
