//go:build with_gvisor

package iosbridge

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestRPCTimeoutKeepsExecutionBounded(t *testing.T) {
	rpc := NewSerialRPC()
	started, release, ended := make(chan struct{}), make(chan struct{}), make(chan struct{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	_, err := rpc.Execute(ctx, func() []byte { close(started); <-release; close(ended); return []byte("完成") })
	<-started
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	ctx2, cancel2 := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel2()
	if _, err := rpc.Execute(ctx2, func() []byte { t.Error("超时后台任务未完成时不应启动新任务"); return nil }); !errors.Is(err, ErrRPCBusy) {
		t.Fatal(err)
	}
	close(release)
	<-ended
	ctx3, cancel3 := context.WithTimeout(context.Background(), time.Second)
	defer cancel3()
	got, err := rpc.Execute(ctx3, func() []byte { return []byte("正常") })
	if err != nil || string(got) != "正常" {
		t.Fatalf("%s %v", got, err)
	}
}

func TestRPCPanicAndCancelledRequest(t *testing.T) {
	rpc := NewSerialRPC()
	if _, err := rpc.Execute(context.Background(), func() []byte { panic("测试异常") }); !errors.Is(err, ErrRPCPanic) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := rpc.Execute(ctx, func() []byte { t.Error("已取消请求不应执行"); return nil }); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := rpc.Execute(context.Background(), func() []byte { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestExpiredQueuedRPCNeverExecutes(t *testing.T) {
	rpc := NewSerialRPC()
	started, release, firstDone := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() {
		_, _ = rpc.Execute(context.Background(), func() []byte { close(started); <-release; return nil })
		close(firstDone)
	}()
	<-started
	ctx, cancel := context.WithCancel(context.Background())
	queued := make(chan error, 1)
	go func() {
		_, err := rpc.Execute(ctx, func() []byte { t.Error("过期排队请求触发副作用"); return nil })
		queued <- err
	}()
	cancel()
	close(release)
	<-firstDone
	select {
	case err := <-queued:
		if err == nil {
			t.Fatal("过期请求未返回错误")
		}
	case <-time.After(time.Second):
		t.Fatal("过期请求阻塞")
	}
}
