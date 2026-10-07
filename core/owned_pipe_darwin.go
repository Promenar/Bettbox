//go:build darwin && !cgo

package main

import (
	stdlog "log"
	"os"

	"github.com/metacubex/mihomo/hub/route"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

// 保留原File对象，不重定义FD、不dup、不创建listener。
func runOwnedPipe() error {
	input, output := os.Stdin, os.Stdout
	redirectOwnedLogs(os.Stderr)
	route.EnableOwnedPipeGuard()
	for _, file := range []*os.File{input, output} {
		fd := file.Fd()
		flags, err := unix.FcntlInt(fd, unix.F_GETFD, 0)
		if err != nil {
			return errOwnedPipe
		}
		if _, err = unix.FcntlInt(fd, unix.F_SETFD, flags|unix.FD_CLOEXEC); err != nil {
			return errOwnedPipe
		}
		flags, err = unix.FcntlInt(fd, unix.F_GETFD, 0)
		if err != nil || flags&unix.FD_CLOEXEC == 0 {
			return errOwnedPipe
		}
		var value unix.Stat_t
		if unix.Fstat(int(fd), &value) != nil || value.Mode&unix.S_IFMT != unix.S_IFIFO {
			return errOwnedPipe
		}
	}
	session := newOwnedSession(&ownedStreams{reader: input, writer: output}, handleAction)
	connMu.Lock()
	ownedBroadcast = session.sendResult
	connMu.Unlock()
	// 初始日志污染由宿主首帧验收拒绝；不扫描或重同步。
	return session.serve()
}

// 仅供显式owned入口；调用者已经保存唯一控制stdout引用。
func redirectOwnedLogs(stderr *os.File) {
	os.Stdout = stderr
	stdlog.SetOutput(stderr)
	logrus.SetOutput(stderr)
}
