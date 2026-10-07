//go:build darwin && !cgo

package main

import (
	"bytes"
	"fmt"
	"io"
	stdlog "log"
	"os"
	"testing"

	"github.com/sirupsen/logrus"
)

// 仅公开fixture pipe；不运行owned入口，不触碰真实stdin或启动子进程。
func TestOwnedLoggerIsolationAndSavedControlWriter(t *testing.T) {
	controlR, controlW, err := os.Pipe()
	if err != nil {
		t.Fatal("fixture pipe失败")
	}
	logsR, logsW, err := os.Pipe()
	if err != nil {
		t.Fatal("fixture pipe失败")
	}
	defer controlR.Close()
	defer logsR.Close()
	oldStdout, oldStdlog, oldLogrus := os.Stdout, stdlog.Writer(), logrus.StandardLogger().Out
	defer func() { os.Stdout = oldStdout; stdlog.SetOutput(oldStdlog); logrus.SetOutput(oldLogrus) }()
	os.Stdout = controlW
	saved := os.Stdout
	redirectOwnedLogs(logsW)
	fmt.Println("公开业务fmt fixture")
	stdlog.Print("公开标准日志fixture")
	logrus.Info("公开logrus fixture")
	if writeFrame(saved, []byte(`{"type":"ack"}`)) != nil {
		t.Fatal("控制writer错误")
	}
	_ = controlW.Close()
	_ = logsW.Close()
	control, _ := io.ReadAll(controlR)
	logs, _ := io.ReadAll(logsR)
	payload, err := readFrame(bytes.NewReader(control))
	if err != nil || string(payload) != `{"type":"ack"}` || bytes.Contains(control, []byte("fixture")) {
		t.Fatal("控制流日志污染")
	}
	for _, text := range []string{"公开业务fmt fixture", "公开标准日志fixture", "公开logrus fixture"} {
		if !bytes.Contains(logs, []byte(text)) {
			t.Fatal("日志没有隔离")
		}
	}
}
