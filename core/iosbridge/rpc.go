//go:build with_gvisor

package iosbridge

import (
	"context"
	"errors"
)

var ErrRPCBusy = errors.New("内核操作尚未完成")
var ErrRPCPanic = errors.New("内核操作异常终止")

// SerialRPC 限制为一个执行工作线程，超时不释放正在工作的令牌。
// 调用方超时后可以重新查询状态，但不能并发修改仍在执行的核心配置。
type SerialRPC struct{ token chan struct{} }

func NewSerialRPC() *SerialRPC {
	rpc := &SerialRPC{token: make(chan struct{}, 1)}
	rpc.token <- struct{}{}
	return rpc
}

func (r *SerialRPC) Execute(ctx context.Context, task func() []byte) ([]byte, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	select {
	case <-r.token:
	case <-ctx.Done():
		return nil, ErrRPCBusy
	}
	if ctx.Err() != nil {
		r.token <- struct{}{}
		return nil, ctx.Err()
	}
	type outcome struct {
		data []byte
		err  error
	}
	result := make(chan outcome, 1)
	go func() {
		defer func() {
			if recover() != nil {
				result <- outcome{err: ErrRPCPanic}
			}
			r.token <- struct{}{}
		}()
		result <- outcome{data: task()}
	}()
	select {
	case value := <-result:
		return value.data, value.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
