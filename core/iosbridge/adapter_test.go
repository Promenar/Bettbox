//go:build with_gvisor

package iosbridge

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
)

type recordingDispatcher struct{ packets chan Packet }

func (d recordingDispatcher) DeliverNetworkPacket(protocol tcpip.NetworkProtocolNumber, pkt *stack.PacketBuffer) {
	version := 4
	if protocol == header.IPv6ProtocolNumber {
		version = 6
	}
	var data []byte
	for _, part := range pkt.AsSlices() {
		data = append(data, part...)
	}
	d.packets <- Packet{Data: data, Version: version}
}
func (d recordingDispatcher) DeliverLinkPacket(tcpip.NetworkProtocolNumber, *stack.PacketBuffer) {}

func TestEndpointBidirectionalDelivery(t *testing.T) {
	a, _ := New(1480, 4)
	defer a.Close()
	ep, _, err := a.NewEndpoint()
	if err != nil {
		t.Fatal(err)
	}
	dispatcher := recordingDispatcher{packets: make(chan Packet, 4)}
	ep.Attach(dispatcher)
	if err := a.Activate(); err != nil {
		t.Fatal(err)
	}
	for _, version := range []int{4, 6} {
		want := ipPacket(version)
		if err := a.PushInbound(want); err != nil {
			t.Fatal(err)
		}
		select {
		case got := <-dispatcher.packets:
			if got.Version != version || !bytes.Equal(got.Data, want) {
				t.Fatal("入包协议或内容不一致")
			}
		case <-time.After(time.Second):
			t.Fatal("协议栈未收到入包")
		}
		var packets stack.PacketBufferList
		packets.PushBack(stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(want)}))
		n, stackErr := ep.WritePackets(packets)
		packets.DecRef()
		if stackErr != nil || n != 1 {
			t.Fatalf("协议栈未交付回包: %d %v", n, stackErr)
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		got, err := a.ReadOutbound(ctx)
		cancel()
		if err != nil || got.Version != version || !bytes.Equal(got.Data, want) {
			t.Fatalf("原生侧未收到正确回包: %v", err)
		}
	}
}

func ipPacket(version int) []byte {
	if version == 6 {
		data := make([]byte, 48)
		data[0] = 0x60
		binary.BigEndian.PutUint16(data[4:6], 8)
		return data
	}
	data := make([]byte, 28)
	data[0] = 0x45
	binary.BigEndian.PutUint16(data[2:4], 28)
	return data
}

func TestPacketValidation(t *testing.T) {
	for _, version := range []int{4, 6} {
		packet := ipPacket(version)
		got, err := ValidatePacket(packet, 1480)
		if err != nil || got != version {
			t.Fatalf("版本 %d: %d %v", version, got, err)
		}
		for _, invalid := range [][]byte{packet[:len(packet)-1], append(packet, 0), packet[:1]} {
			if _, err := ValidatePacket(invalid, 1480); !errors.Is(err, ErrInvalidPacket) {
				t.Fatalf("未拒绝损坏包: %v", err)
			}
		}
	}
	if _, err := ValidatePacket([]byte{0x70}, 1480); !errors.Is(err, ErrInvalidPacket) {
		t.Fatal(err)
	}
	if _, err := ValidatePacket(ipPacket(6), 40); !errors.Is(err, ErrInvalidPacket) {
		t.Fatal(err)
	}
}

func TestQueueOwnershipAndBackpressure(t *testing.T) {
	a, _ := New(1480, 1)
	defer a.Close()
	// 单独检验队列所有权；端点交付由后续协议栈集成测试覆盖。
	a.active = true
	packet := ipPacket(4)
	if err := a.PushInbound(packet); err != nil {
		t.Fatal(err)
	}
	packet[8] = 99
	if a.inbound != nil {
		got := <-a.inbound
		if got.Data[8] == 99 {
			t.Fatal("入包引用调用方内存")
		}
	}
	if err := a.PushInbound(ipPacket(6)); err != nil {
		t.Fatal(err)
	}
	if err := a.PushInbound(ipPacket(4)); !errors.Is(err, ErrQueueFull) {
		t.Fatal(err)
	}
	out := ipPacket(6)
	if _, err := a.Write(out); err != nil {
		t.Fatal(err)
	}
	out[7] = 99
	if _, err := a.Write(ipPacket(4)); !errors.Is(err, ErrQueueFull) {
		t.Fatal(err)
	}
	got, err := a.PollOutbound()
	if err != nil || got.Version != 6 || got.Data[7] == 99 {
		t.Fatalf("回包所有权错误: %+v %v", got, err)
	}
}

func TestCloseUnblocksReaderAndRejectsWrites(t *testing.T) {
	a, _ := New(1480, 2)
	result := make(chan error, 1)
	go func() { _, err := a.ReadOutbound(context.Background()); result <- err }()
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if !errors.Is(err, ErrClosed) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("关闭未解除读取阻塞")
	}
	if err := a.PushInbound(ipPacket(4)); !errors.Is(err, ErrClosed) {
		t.Fatal(err)
	}
	if _, err := a.Write(ipPacket(6)); !errors.Is(err, ErrClosed) {
		t.Fatal(err)
	}
	if _, _, err := a.NewEndpoint(); !errors.Is(err, ErrClosed) {
		t.Fatal(err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestEndpointAndPacketBufferOutput(t *testing.T) {
	a, _ := New(1480, 2)
	defer a.Close()
	if err := a.Activate(); !errors.Is(err, ErrNotReady) {
		t.Fatal(err)
	}
	ep, _, err := a.NewEndpoint()
	if err != nil || ep.MTU() != 1480 {
		t.Fatalf("端点无效: %v", err)
	}
	if _, _, err := a.NewEndpoint(); !errors.Is(err, ErrEndpointStarted) {
		t.Fatal(err)
	}
	if err := a.PushInbound(ipPacket(4)); !errors.Is(err, ErrNotReady) {
		t.Fatal(err)
	}
	for _, version := range []int{4, 6} {
		packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(ipPacket(version))})
		packet.NetworkProtocolNumber = header.IPv4ProtocolNumber
		if version == 6 {
			packet.NetworkProtocolNumber = header.IPv6ProtocolNumber
		}
		if _, err := a.WritePacket(packet); err != nil {
			t.Fatal(err)
		}
		packet.DecRef()
		got, err := a.ReadOutbound(context.Background())
		if err != nil || got.Version != version {
			t.Fatalf("回包版本错误: %d %v", got.Version, err)
		}
	}
}

func TestConcurrentCloseAndProducers(t *testing.T) {
	a, _ := New(1480, 2)
	_, _, _ = a.NewEndpoint()
	var workers sync.WaitGroup
	for n := 0; n < 8; n++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for i := 0; i < 100; i++ {
				_ = a.PushInbound(ipPacket(4))
				_, _ = a.Write(ipPacket(6))
			}
		}()
	}
	workers.Add(2)
	for n := 0; n < 2; n++ {
		go func() { defer workers.Done(); _ = a.Close() }()
	}
	workers.Wait()
	if _, err := a.PollOutbound(); !errors.Is(err, ErrClosed) {
		t.Fatal(err)
	}
}

func TestCloseWithQueuedPacketsAndConcurrentReaders(t *testing.T) {
	for iteration := 0; iteration < 100; iteration++ {
		a, _ := New(1480, 2)
		_, _ = a.Write(ipPacket(4))
		_, _ = a.Write(ipPacket(6))
		var readers sync.WaitGroup
		for n := 0; n < 4; n++ {
			readers.Add(1)
			go func() { defer readers.Done(); _, _ = a.ReadOutbound(context.Background()) }()
		}
		done := make(chan struct{})
		go func() { _ = a.Close(); readers.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("关闭与含包读取发生死锁")
		}
	}
}
