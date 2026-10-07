//go:build with_gvisor

// Package iosbridge 提供公开 packetFlow 与 gVisor 之间的有界包传输。
package iosbridge

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"sync"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	tun "github.com/metacubex/sing-tun"
)

var (
	ErrClosed          = errors.New("包桥接已关闭")
	ErrQueueFull       = errors.New("包队列已满")
	ErrInvalidPacket   = errors.New("IP 包格式或长度无效")
	ErrEndpointStarted = errors.New("协议栈端点已经创建")
	ErrPacketMode      = errors.New("包桥接仅支持 gVisor 端点模式")
	ErrNotReady        = errors.New("协议栈尚未附着包桥接")
)

// Packet 的数据由桥接独立持有，不保留 Swift 或 C 调用方内存。
type Packet struct {
	Data    []byte
	Version int
}

// Adapter 的两端队列和 gVisor 输出队列均受容量约束。
// 创建端点后只有协议栈消费入包，调用方通过 ReadOutbound 消费回包。
type Adapter struct {
	mu       sync.Mutex
	closed   bool
	mtu      uint32
	capacity int
	inbound  chan Packet
	outbound chan Packet
	ctx      context.Context
	cancel   context.CancelFunc
	endpoint *channel.Endpoint
	ready    chan struct{}
	active   bool
	workers  sync.WaitGroup
}

var _ tun.GVisorTun = (*Adapter)(nil)

func New(mtu uint32, capacity int) (*Adapter, error) {
	if mtu < 1280 || mtu > 65535 || capacity < 1 || capacity > 4096 || uint64(mtu)*uint64(capacity) > 8*1024*1024 {
		return nil, errors.New("MTU 或队列容量超出允许范围")
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Adapter{mtu: mtu, capacity: capacity, inbound: make(chan Packet, capacity), outbound: make(chan Packet, capacity), ctx: ctx, cancel: cancel, ready: make(chan struct{})}, nil
}

func (a *Adapter) MTU() uint32 { return a.mtu }

// ValidatePacket 检查裸 IP 包的声明长度，拒绝截断及额外尾部数据。
func ValidatePacket(data []byte, mtu uint32) (int, error) {
	if len(data) == 0 || len(data) > int(mtu) {
		return 0, ErrInvalidPacket
	}
	switch data[0] >> 4 {
	case 4:
		if len(data) < 20 {
			return 0, ErrInvalidPacket
		}
		hlen := int(data[0]&15) * 4
		if hlen < 20 || hlen > len(data) || int(binary.BigEndian.Uint16(data[2:4])) != len(data) {
			return 0, ErrInvalidPacket
		}
		return 4, nil
	case 6:
		if len(data) < 40 || int(binary.BigEndian.Uint16(data[4:6]))+40 != len(data) {
			return 0, ErrInvalidPacket
		}
		return 6, nil
	default:
		return 0, ErrInvalidPacket
	}
}

// PushInbound 不阻塞调用 packetFlow 的线程；队满由调用方明确处理丢包。
func (a *Adapter) PushInbound(data []byte) error {
	version, err := ValidatePacket(data, a.mtu)
	if err != nil {
		return err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return ErrClosed
	}
	if !a.active {
		return ErrNotReady
	}
	if len(a.inbound) == cap(a.inbound) {
		return ErrQueueFull
	}
	packet := Packet{Data: append([]byte(nil), data...), Version: version}
	select {
	case a.inbound <- packet:
		return nil
	default:
		return ErrQueueFull
	}
}

func (a *Adapter) enqueueOutbound(data []byte) (int, error) {
	version, err := ValidatePacket(data, a.mtu)
	if err != nil {
		return 0, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return 0, ErrClosed
	}
	if len(a.outbound) == cap(a.outbound) {
		return 0, ErrQueueFull
	}
	select {
	case a.outbound <- Packet{Data: append([]byte(nil), data...), Version: version}:
		return len(data), nil
	default:
		return 0, ErrQueueFull
	}
}

// ReadOutbound 支持取消；关闭后不再交付旧队列中的包。
func (a *Adapter) ReadOutbound(ctx context.Context) (Packet, error) {
	select {
	case <-a.ctx.Done():
		return Packet{}, ErrClosed
	case <-ctx.Done():
		return Packet{}, ctx.Err()
	case packet := <-a.outbound:
		a.mu.Lock()
		closed := a.closed
		a.mu.Unlock()
		if closed {
			return Packet{}, ErrClosed
		}
		return packet, nil
	}
}

// PollOutbound 是供原生端批量轮询的非阻塞入口。
func (a *Adapter) PollOutbound() (Packet, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return Packet{}, ErrClosed
	}
	select {
	case packet := <-a.outbound:
		return packet, nil
	default:
		return Packet{}, nil
	}
}

// Read 禁止绕过端点消费入包，避免两条消费者竞争导致包丢失。
func (a *Adapter) Read([]byte) (int, error)       { return 0, ErrPacketMode }
func (a *Adapter) Write(data []byte) (int, error) { return a.enqueueOutbound(data) }

func (a *Adapter) WritePacket(packet *stack.PacketBuffer) (int, error) {
	slices := packet.AsSlices()
	size := 0
	for _, part := range slices {
		size += len(part)
	}
	if size > int(a.mtu) {
		return 0, ErrInvalidPacket
	}
	data := make([]byte, 0, size)
	for _, part := range slices {
		data = append(data, part...)
	}
	return a.enqueueOutbound(data)
}

func (a *Adapter) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return nil, stack.NICOptions{}, ErrClosed
	}
	if a.endpoint != nil {
		return nil, stack.NICOptions{}, ErrEndpointStarted
	}
	a.endpoint = channel.New(a.capacity, a.mtu, tcpip.LinkAddress(""))
	a.workers.Add(2)
	go a.injectLoop(a.endpoint)
	go a.outputLoop(a.endpoint)
	return a.endpoint, stack.NICOptions{}, nil
}

// Activate 必须在协议栈 Start 成功后调用，再允许 Swift 开始读 packetFlow。
func (a *Adapter) Activate() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.closed {
		return ErrClosed
	}
	if a.endpoint == nil || !a.endpoint.IsAttached() {
		return ErrNotReady
	}
	if !a.active {
		a.active = true
		close(a.ready)
	}
	return nil
}

func (a *Adapter) injectLoop(endpoint *channel.Endpoint) {
	defer a.workers.Done()
	select {
	case <-a.ctx.Done():
		return
	case <-a.ready:
	}
	for {
		select {
		case <-a.ctx.Done():
			return
		case packet := <-a.inbound:
			pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet.Data)})
			protocol := header.IPv4ProtocolNumber
			if packet.Version == 6 {
				protocol = header.IPv6ProtocolNumber
			}
			endpoint.InjectInbound(protocol, pkt)
			pkt.DecRef()
		}
	}
}

func (a *Adapter) outputLoop(endpoint *channel.Endpoint) {
	defer a.workers.Done()
	for {
		pkt := endpoint.ReadContext(a.ctx)
		if pkt == nil {
			return
		}
		// 回包队满时丢弃当前包；不会阻塞协议栈或累计无界内存。
		_, _ = a.WritePacket(pkt)
		pkt.DecRef()
	}
}

// Close 可重复调用，先取消工作线程再清空包引用，不关闭仍可能被生产者使用的 channel。
func (a *Adapter) Close() error {
	a.mu.Lock()
	if !a.closed {
		a.closed = true
		a.cancel()
	}
	endpoint := a.endpoint
	a.mu.Unlock()
	a.workers.Wait()
	if endpoint != nil {
		endpoint.Attach(nil)
		endpoint.Close()
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for {
		select {
		case <-a.inbound:
		default:
			goto drainedInbound
		}
	}
drainedInbound:
	for {
		select {
		case <-a.outbound:
		default:
			return nil
		}
	}
}

var _ io.ReadWriteCloser = (*Adapter)(nil)
