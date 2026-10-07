package http

import (
	"bufio"
	"io"
	"sync"
	"time"
)

// 单请求锁线性化EOF、响应阶段和watcher入场；不设正文或连接总量限制。
type blindRequestState struct {
	mu             sync.Mutex
	conn           *blindConn
	reader         *bufio.Reader
	admission      bool
	bodyEOF        bool
	responseReady  bool
	earlyResponse  bool
	responseDone   bool
	watcherStarted bool
	stopping       bool
	terminal       bool
	joined         chan struct{}
}

func newBlindRequest(conn *blindConn, reader *bufio.Reader) *blindRequestState {
	state := &blindRequestState{conn: conn, reader: reader, admission: true, joined: make(chan struct{})}
	conn.owner.mu.Lock()
	conn.request = state
	conn.owner.mu.Unlock()
	return state
}

func (r *blindRequestState) onBodyEOF() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.bodyEOF = true
	if !r.admission || r.watcherStarted || r.conn.ctx.Err() != nil {
		return
	}
	// owner锁内Add，随后启动；Close先关闭admission/owner入场，不能迟到Add。
	if r.conn.startWatcher(r.watch) {
		r.watcherStarted = true
	}
}

func (r *blindRequestState) onResponseReady() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.responseReady = true
	if !r.bodyEOF {
		r.earlyResponse = true
	}
	return r.earlyResponse // force Close只决定响应后不接收下一请求，不中止活跃上传。
}

func (r *blindRequestState) closeAdmission() {
	r.mu.Lock()
	r.admission = false
	r.stopping = true
	r.mu.Unlock()
}

func (r *blindRequestState) watch() {
	defer close(r.joined)
	for {
		r.mu.Lock()
		stop := r.stopping
		r.mu.Unlock()
		if stop {
			return
		}
		// 未消费prefix保留；多1字节探测，仅该缓冲有独立预算。
		size := r.reader.Buffered() + 1
		if size > blindHeaderBytes+1 {
			r.fail()
			return
		}
		prefix, err := r.reader.Peek(size)
		r.mu.Lock()
		stop = r.stopping
		r.mu.Unlock()
		if stop {
			return
		} // 主动读期限唤醒不能误判EOF，也不取消正常响应。
		if len(prefix) > blindHeaderBytes {
			r.fail()
			return
		}
		if err != nil {
			// 包括真正EOF；固定关闭，不记录或输出prefix。
			if err == io.EOF {
				r.fail()
				return
			}
			r.fail()
			return
		}
	}
}

func (r *blindRequestState) fail() {
	r.mu.Lock()
	if r.stopping {
		r.mu.Unlock()
		return
	}
	r.terminal = true
	r.admission = false
	r.mu.Unlock()
	_ = r.conn.Close() // 取消上游context、唤醒owned读取；Close不会等待自身watcher。
}

func (r *blindRequestState) onResponseDone() bool {
	r.mu.Lock()
	r.admission = false
	r.responseDone = true
	r.stopping = true
	started, bodyEOF, early := r.watcherStarted, r.bodyEOF, r.earlyResponse
	r.mu.Unlock()
	if early && !bodyEOF {
		_ = r.conn.Close() // 活跃正文不设置ReadDeadline，不排空无限正文。
		return false
	}
	if started {
		select {
		case <-r.joined:
		default:
			if r.conn.SetReadDeadline(time.Now()) != nil {
				_ = r.conn.Close()
				return false
			}
		}
		timer := time.NewTimer(time.Second)
		defer timer.Stop()
		select {
		case <-r.joined:
		case <-timer.C:
			_ = r.conn.Close()
			return false
		}
		// join后才恢复，写方向未设置期限；失败不能解析下一请求。
		if r.conn.SetReadDeadline(time.Time{}) != nil {
			_ = r.conn.Close()
			return false
		}
	}
	r.mu.Lock()
	terminal := r.terminal
	r.mu.Unlock()
	r.conn.owner.mu.Lock()
	if r.conn.request == r {
		r.conn.request = nil
	}
	r.conn.owner.mu.Unlock()
	return !terminal && r.conn.ctx.Err() == nil
}
