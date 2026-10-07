package tunnel

import (
	"context"
	"errors"
	"net"
	"testing"
)

var fixtureBindError = errors.New("公开夹具绑定失败")

type constructorFixtureConfig struct{ tcpCalls, udpCalls int }

func (c *constructorFixtureConfig) Listen(context.Context, string, string) (net.Listener, error) {
	c.tcpCalls++
	return nil, fixtureBindError
}
func (c *constructorFixtureConfig) ListenPacket(context.Context, string, string) (net.PacketConn, error) {
	c.udpCalls++
	return nil, fixtureBindError
}

// 无效目标不得进入绑定；旧顺序会先调用绑定器并掩盖目标错误。
func TestInvalidTargetNeverBinds(t *testing.T) {
	t.Run("TCP", func(t *testing.T) {
		config := &constructorFixtureConfig{}
		value, err := New("127.0.0.1:0", "invalid-target", "", config, nil)
		if value != nil || err == nil {
			t.Fatal("无效TCP目标未拒绝")
		}
		if config.tcpCalls != 0 {
			t.Fatal("无效TCP目标进入了绑定")
		}
	})
	t.Run("UDP", func(t *testing.T) {
		config := &constructorFixtureConfig{}
		value, err := NewUDP("127.0.0.1:0", "invalid-target", "", config, nil)
		if value != nil || err == nil {
			t.Fatal("无效UDP目标未拒绝")
		}
		if config.udpCalls != 0 {
			t.Fatal("无效UDP目标进入了绑定")
		}
	})
}

func TestValidTargetPreservesBindFailure(t *testing.T) {
	config := &constructorFixtureConfig{}
	tcp, tcpErr := New("127.0.0.1:0", "127.0.0.1:12345", "", config, nil)
	udp, udpErr := NewUDP("127.0.0.1:0", "127.0.0.1:12345", "", config, nil)
	if tcp != nil || udp != nil || !errors.Is(tcpErr, fixtureBindError) || !errors.Is(udpErr, fixtureBindError) {
		t.Fatal("合法目标的绑定错误被改变")
	}
	if config.tcpCalls != 1 || config.udpCalls != 1 {
		t.Fatal("合法目标绑定次数错误")
	}
}
