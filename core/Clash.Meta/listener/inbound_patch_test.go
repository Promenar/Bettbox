package listener

import (
	"context"
	"errors"
	"fmt"
	"net"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	IN "github.com/metacubex/mihomo/listener/inbound"
)

type patchFixtureConfig struct{ version string }

func (c patchFixtureConfig) Name() string { return c.version }
func (c patchFixtureConfig) Equal(other C.InboundConfig) bool {
	value, ok := other.(patchFixtureConfig)
	return ok && value == c
}

type patchRealmSocket struct {
	net.Listener
	fail bool
}

func (s *patchRealmSocket) Close() error {
	if s.fail {
		return errors.New("公开Realm关闭失败")
	}
	err := s.Listener.Close()
	if errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

type patchRealmListenConfig struct{ sockets []*patchRealmSocket }

func (c *patchRealmListenConfig) Listen(ctx context.Context, network, address string) (net.Listener, error) {
	l, err := (&net.ListenConfig{}).Listen(ctx, network, address)
	if err != nil {
		return nil, err
	}
	s := &patchRealmSocket{Listener: l, fail: true}
	c.sockets = append(c.sockets, s)
	return s, nil
}
func (*patchRealmListenConfig) ListenPacket(ctx context.Context, network, address string) (net.PacketConn, error) {
	return (&net.ListenConfig{}).ListenPacket(ctx, network, address)
}

func TestInboundPatchActualRealmPartialObjectSurvivesFailedCleanup(t *testing.T) {
	patchFixtureCleanup(t)
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = occupied.Close() })
	lc := &patchRealmListenConfig{}
	t.Cleanup(func() {
		for _, socket := range lc.sockets {
			socket.fail = false
			_ = socket.Close()
		}
	})
	options := IN.DefaultHysteria2RealmServerOption()
	options.BaseOption = IN.BaseOption{NameStr: "公开Realm部分", Listen: "127.0.0.1", Port: fmt.Sprintf("0,%d", occupied.Addr().(*net.TCPAddr).Port), ListenConfigForAPI: lc}
	options.Token = "PUBLIC_FIXTURE_TOKEN"
	value, err := IN.NewHysteria2RealmServer(options)
	if err != nil {
		t.Fatal(err)
	}
	if PatchInboundListenersChecked(map[string]C.InboundListener{value.Name(): value}, nil, true) == nil || len(lc.sockets) != 1 || inboundListeners[value.Name()] != value {
		t.Fatal("真实Realm部分对象没有登记")
	}
	if StopListenerChecked() == nil || inboundListeners[value.Name()] != value {
		t.Fatal("真实Realm关闭失败责任被移除")
	}
	lc.sockets[0].fail = false
	address := lc.sockets[0].Addr().String()
	if err := StopListenerChecked(); err != nil {
		t.Fatal(err)
	}
	rebound, err := net.Listen("tcp", address)
	if err != nil {
		t.Fatal("真实Realm确认关闭后不能重新绑定")
	}
	_ = rebound.Close()
}

type patchFixtureInbound struct {
	version     string
	listenFail  bool
	listenPanic bool
	closeFail   bool
	strictClose bool
	listenCalls int
	closeCalls  int
	socket      net.Listener
}

func (f *patchFixtureInbound) Name() string    { return "公开命名监听" }
func (f *patchFixtureInbound) Address() string { return f.RawAddress() }
func (f *patchFixtureInbound) RawAddress() string {
	if f.socket == nil {
		return ""
	}
	return f.socket.Addr().String()
}
func (f *patchFixtureInbound) Config() C.InboundConfig { return patchFixtureConfig{f.version} }
func (f *patchFixtureInbound) Listen(C.Tunnel) error {
	f.listenCalls++
	var err error
	f.socket, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	if f.listenPanic {
		panic("公开Listen失败")
	}
	if f.listenFail {
		return errors.New("公开部分创建失败")
	}
	return nil
}
func (f *patchFixtureInbound) Close() error {
	f.closeCalls++
	if f.closeFail {
		return errors.New("公开Close失败")
	}
	if f.socket == nil {
		return nil
	}
	err := f.socket.Close()
	if !f.strictClose && errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

func patchFixtureCleanup(t *testing.T, fixtures ...*patchFixtureInbound) {
	t.Helper()
	previous := inboundListeners
	inboundListeners = map[string]C.InboundListener{}
	t.Cleanup(func() {
		for _, f := range fixtures {
			f.closeFail = false
			_ = f.Close()
		}
		if err := StopListenerChecked(); err != nil {
			t.Error("公开夹具清理未确认")
		}
		inboundListeners = previous
	})
}

func TestInboundPatchPartialListenRetainsRealSocket(t *testing.T) {
	partial := &patchFixtureInbound{version: "公开部分", listenFail: true}
	patchFixtureCleanup(t, partial)
	PatchInboundListeners(map[string]C.InboundListener{"公开部分": partial}, nil, true)
	if partial.socket == nil {
		t.Fatal("未真实创建socket")
	}
	if inboundListeners["公开部分"] != partial || !HasListenerResponsibility() {
		t.Fatal("Listen失败丢失已创建真实socket责任")
	}
	if err := StopListenerChecked(); err != nil {
		t.Fatal(err)
	}
	rebound, err := net.Listen("tcp", partial.socket.Addr().String())
	if err != nil {
		t.Fatal("检查式停止未释放真实端口")
	}
	_ = rebound.Close()
}

func TestInboundPatchFailedReplacementKeepsOldSocket(t *testing.T) {
	old := &patchFixtureInbound{version: "公开旧", closeFail: true}
	newValue := &patchFixtureInbound{version: "公开新"}
	patchFixtureCleanup(t, old, newValue)
	PatchInboundListeners(map[string]C.InboundListener{"公开替换": old}, nil, true)
	PatchInboundListeners(map[string]C.InboundListener{"公开替换": newValue}, nil, true)
	if inboundListeners["公开替换"] != old || newValue.listenCalls != 0 || old.closeCalls != 1 {
		t.Fatal("旧socket关闭失败后被覆盖或创建了新监听")
	}
}

func TestInboundPatchFailedDropRetainsOldSocket(t *testing.T) {
	old := &patchFixtureInbound{version: "公开删除", closeFail: true}
	patchFixtureCleanup(t, old)
	PatchInboundListeners(map[string]C.InboundListener{"公开删除": old}, nil, true)
	PatchInboundListeners(map[string]C.InboundListener{}, nil, true)
	if inboundListeners["公开删除"] != old || !HasListenerResponsibility() {
		t.Fatal("关闭失败的删除遗失真实socket")
	}
}

func TestInboundPatchListenPanicRetainsRealSocket(t *testing.T) {
	partial := &patchFixtureInbound{version: "公开恐慌", listenPanic: true}
	patchFixtureCleanup(t, partial)
	panicked := false
	func() {
		defer func() {
			if recover() != nil {
				panicked = true
			}
		}()
		PatchInboundListeners(map[string]C.InboundListener{"公开恐慌": partial}, nil, true)
	}()
	if panicked || partial.socket == nil || inboundListeners["公开恐慌"] != partial {
		t.Fatal("部分构造panic越界或丢失真实资源责任")
	}
}

func TestInboundPatchUnknownBlocksReuseAndNewConstructionUntilStop(t *testing.T) {
	partial := &patchFixtureInbound{version: "公开部分", listenFail: true}
	same := &patchFixtureInbound{version: partial.version}
	other := &patchFixtureInbound{version: "公开其它"}
	patchFixtureCleanup(t, partial, same, other)
	if PatchInboundListenersChecked(map[string]C.InboundListener{"部分": partial}, nil, true) == nil {
		t.Fatal("部分创建错误未返回")
	}
	for _, candidate := range []map[string]C.InboundListener{{"部分": same}, {"其它": other}} {
		if PatchInboundListenersChecked(candidate, nil, true) == nil {
			t.Fatal("未知对象被相同配置复用或新构造绕过")
		}
	}
	if partial.listenCalls != 1 || partial.closeCalls != 0 || same.listenCalls != 0 || other.listenCalls != 0 {
		t.Fatal("未知状态触发了隐式清理或新建")
	}
	if err := StopListenerChecked(); err != nil {
		t.Fatal(err)
	}
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"其它": other}, nil, true); err != nil {
		t.Fatal("显式停止确认后不能重新创建")
	}
}

func TestInboundPatchConfirmedReuseAndAliasesPreserveRealSocket(t *testing.T) {
	old := &patchFixtureInbound{version: "公开相同"}
	same := &patchFixtureInbound{version: old.version}
	patchFixtureCleanup(t, old, same)
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"主": old, "别名": old}, nil, true); err != nil {
		t.Fatal(err)
	}
	if old.listenCalls != 1 {
		t.Fatal("同对象别名重复构造并覆盖socket")
	}
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"主": same}, nil, true); err != nil {
		t.Fatal(err)
	}
	if old.closeCalls != 0 || same.listenCalls != 0 {
		// 主名称按相同配置复用旧对象；删除别名不能关闭仍被主名称持有的socket。
		t.Fatalf("相同配置或别名责任错误：旧关闭=%d，新创建=%d", old.closeCalls, same.listenCalls)
	}
}

func TestInboundPatchSameConfigNewAliasReusesCanonicalSocket(t *testing.T) {
	old := &patchFixtureInbound{version: "公开相同"}
	same := &patchFixtureInbound{version: old.version}
	patchFixtureCleanup(t, old, same)
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"主": old}, nil, true); err != nil {
		t.Fatal(err)
	}
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"主": same, "别名": same}, nil, true); err != nil {
		t.Fatal(err)
	}
	if same.listenCalls != 0 || old.listenCalls != 1 || inboundListeners["主"] != old || inboundListeners["别名"] != old {
		t.Fatal("相同配置新增别名重复创建了socket")
	}
}

func TestInboundPatchRetainedAliasKeepsOldSocketWhenReplacingOneName(t *testing.T) {
	old := &patchFixtureInbound{version: "公开旧"}
	newValue := &patchFixtureInbound{version: "公开新"}
	patchFixtureCleanup(t, old, newValue)
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"主": old, "保留": old}, nil, true); err != nil {
		t.Fatal(err)
	}
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"主": newValue}, nil, false); err != nil {
		t.Fatal(err)
	}
	if old.closeCalls != 0 || inboundListeners["保留"] != old {
		t.Fatal("替换一个名称提前关闭了保留别名")
	}
	peer, err := net.Dial("tcp", old.socket.Addr().String())
	if err != nil {
		t.Fatal("保留名称的真实socket不可连接")
	}
	_ = peer.Close()
}

func TestInboundPatchReplacementFailureRemovesAllConfirmedClosedAliases(t *testing.T) {
	old := &patchFixtureInbound{version: "公开旧", strictClose: true}
	first := &patchFixtureInbound{version: "公开新一", listenFail: true}
	second := &patchFixtureInbound{version: "公开新二", listenFail: true}
	patchFixtureCleanup(t, old, first, second)
	if err := PatchInboundListenersChecked(map[string]C.InboundListener{"一": old, "二": old}, nil, true); err != nil {
		t.Fatal(err)
	}
	address := old.socket.Addr().String()
	if PatchInboundListenersChecked(map[string]C.InboundListener{"一": first, "二": second}, nil, true) == nil {
		t.Fatal("替换构造失败没有返回")
	}
	if err := StopListenerChecked(); err != nil || HasListenerResponsibility() || old.closeCalls != 1 {
		t.Fatal("部分替换失败遗留已关闭别名或重复关闭旧对象")
	}
	rebound, err := net.Listen("tcp", address)
	if err != nil {
		t.Fatal("旧对象确认关闭后端口未释放")
	}
	_ = rebound.Close()
}

func TestInboundPatchDropFailureRemovesAllConfirmedClosedAliases(t *testing.T) {
	for round := 0; round < 16; round++ {
		t.Run(fmt.Sprint(round), func(t *testing.T) {
			old := &patchFixtureInbound{version: "公开旧", strictClose: true}
			bad := &patchFixtureInbound{version: "公开关闭失败", closeFail: true}
			patchFixtureCleanup(t, old, bad)
			if err := PatchInboundListenersChecked(map[string]C.InboundListener{"一": old, "二": old, "三": bad}, nil, true); err != nil {
				t.Fatal(err)
			}
			if PatchInboundListenersChecked(map[string]C.InboundListener{}, nil, true) == nil {
				t.Fatal("删除关闭失败没有返回")
			}
			bad.closeFail = false
			if err := StopListenerChecked(); err != nil || HasListenerResponsibility() || old.closeCalls != 1 {
				t.Fatal("删除失败遗留已关闭别名或重复关闭对象")
			}
		})
	}
}
