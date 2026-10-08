package androidstartup

import (
	"errors"
	"testing"
)

type protectRawConn struct {
	controlError error
	skipCallback bool
}

func (c protectRawConn) Control(fn func(uintptr)) error {
	if !c.skipCallback {
		fn(42)
	}
	return c.controlError
}

func (protectRawConn) Read(func(uintptr) bool) error  { return nil }
func (protectRawConn) Write(func(uintptr) bool) error { return nil }

func TestProtectSocketRejectsFalseAndPreservesControlError(t *testing.T) {
	controlError := errors.New("虚构 Control 失败")
	for _, tc := range []struct {
		name      string
		conn      protectRawConn
		protected bool
		wantError bool
	}{
		{name: "保护成功", protected: true},
		{name: "保护拒绝", wantError: true},
		{name: "Control错误优先", conn: protectRawConn{controlError: controlError}, wantError: true},
		{name: "未调用保护回调", conn: protectRawConn{skipCallback: true}, protected: true, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			err := ProtectSocket(tc.conn, func(fd int) bool {
				calls++
				if fd != 42 {
					t.Fatalf("保护了错误的 FD：%d", fd)
				}
				return tc.protected
			})
			if (err != nil) != tc.wantError {
				t.Fatalf("保护结果错误：%v", err)
			}
			if tc.conn.controlError != nil && !errors.Is(err, controlError) {
				t.Fatalf("Control 首错丢失：%v", err)
			}
			wantCalls := 1
			if tc.conn.skipCallback {
				wantCalls = 0
			}
			if calls != wantCalls {
				t.Fatalf("保护回调次数错误：%d", calls)
			}
		})
	}
}
