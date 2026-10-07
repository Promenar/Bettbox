//go:build !cgo

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"
)

const ownedHandshakeLimit = 4 * 1024
const ownedBusinessLimit = 10 * 1024 * 1024
const ownedHandshakeBudget = 5 * time.Second

var errOwnedPipe = errors.New("专用控制会话拒绝")

type ownedStreams struct {
	reader io.ReadCloser
	writer io.WriteCloser
}

func (s *ownedStreams) Read(p []byte) (int, error)  { return s.reader.Read(p) }
func (s *ownedStreams) Write(p []byte) (int, error) { return s.writer.Write(p) }
func (s *ownedStreams) Close() error {
	first := s.reader.Close()
	second := s.writer.Close()
	if first != nil || second != nil {
		return errOwnedPipe
	}
	return nil
}

type ownedRead struct {
	payload []byte
	err     error
}
type ownedSession struct {
	stream            io.ReadWriteCloser
	dispatch          func(*Action, ActionResult)
	control           *ownedListenerOwner
	mu                sync.Mutex
	writer            sync.Mutex
	closed            bool
	ready             bool
	generation        int64
	ctx               context.Context
	cancel            context.CancelFunc
	done              chan struct{}
	readRequests      chan int
	readResults       chan ownedRead
	budget            time.Duration
	now               func() time.Time
	handshakeDeadline time.Time
}

func newOwnedSession(stream io.ReadWriteCloser, dispatch func(*Action, ActionResult)) *ownedSession {
	ctx, cancel := context.WithCancel(context.Background())
	return &ownedSession{stream: stream, dispatch: dispatch, ctx: ctx, cancel: cancel,
		done: make(chan struct{}), readRequests: make(chan int), readResults: make(chan ownedRead, 1), budget: ownedHandshakeBudget, now: time.Now}
}

// stop只证明撤销，不等待writer或File.Close。唯一closer与reader可能持续到main退出。
// 真实停止必须由宿主观察进程exitCode，不能将done解释为所有FD已经关闭。
func (s *ownedSession) stop() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.ready = false
	if s.control != nil {
		s.control.revokeLocked()
	}
	close(s.done)
	s.mu.Unlock()
	s.cancel()
	go func() { _ = s.stream.Close() }()
}

func ownedReadFrame(reader io.Reader, limit int) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header[:])
	if size == 0 || uint64(size) > uint64(limit) {
		return nil, errOwnedPipe
	}
	value := make([]byte, int(size))
	if _, err := io.ReadFull(reader, value); err != nil {
		return nil, errOwnedPipe
	}
	return value, nil
}

// 每会话仅一个reader；主循环明确授予下一次读取预算，不提前解析业务帧。
func (s *ownedSession) readWorker() {
	for {
		select {
		case <-s.done:
			return
		case limit := <-s.readRequests:
			value, err := ownedReadFrame(s.stream, limit)
			select {
			case s.readResults <- ownedRead{value, err}:
			case <-s.done:
				return
			}
		}
	}
}

func (s *ownedSession) read(limit int, deadline <-chan time.Time, expiry time.Time) ([]byte, error) {
	if !expiry.IsZero() && !s.now().Before(expiry) {
		return nil, errOwnedPipe
	}
	select {
	case s.readRequests <- limit:
	case <-s.done:
		return nil, errOwnedPipe
	case <-deadline:
		return nil, errOwnedPipe
	}
	select {
	case result := <-s.readResults:
		// select可能选择已经就绪的结果；成功仍须核验单调时间边界。
		if !expiry.IsZero() && !s.now().Before(expiry) {
			return nil, errOwnedPipe
		}
		return result.payload, result.err
	case <-s.done:
		return nil, errOwnedPipe
	case <-deadline:
		return nil, errOwnedPipe
	}
}

// 严格顶层对象：拒绝重复/未知字段、尾随值及非对象，不记录原文。
func ownedObject(value []byte, keys ...string) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(value))
	first, err := decoder.Token()
	if err != nil || first != json.Delim('{') {
		return nil, errOwnedPipe
	}
	allowed := map[string]bool{}
	for _, key := range keys {
		allowed[key] = true
	}
	result := map[string]json.RawMessage{}
	for decoder.More() {
		token, err := decoder.Token()
		key, valid := token.(string)
		if err != nil || !valid || !allowed[key] {
			return nil, errOwnedPipe
		}
		if _, duplicate := result[key]; duplicate {
			return nil, errOwnedPipe
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return nil, errOwnedPipe
		}
		result[key] = raw
	}
	last, err := decoder.Token()
	if err != nil || last != json.Delim('}') || len(result) != len(keys) {
		return nil, errOwnedPipe
	}
	var extra json.RawMessage
	if decoder.Decode(&extra) != io.EOF {
		return nil, errOwnedPipe
	}
	return result, nil
}

func ownedGeneration(values map[string]json.RawMessage) (int64, error) {
	var protocol, generation int64
	if json.Unmarshal(values["protocol"], &protocol) != nil || protocol != 1 ||
		json.Unmarshal(values["generation"], &generation) != nil || generation <= 0 {
		return 0, errOwnedPipe
	}
	return generation, nil
}

func (s *ownedSession) write(payload []byte, handshake bool) error {
	s.writer.Lock()
	defer s.writer.Unlock()
	s.mu.Lock()
	allowed := !s.closed && ((handshake && s.now().Before(s.handshakeDeadline)) || (!handshake && s.ready))
	s.mu.Unlock()
	if !allowed {
		return errOwnedPipe
	}
	if len(payload) == 0 || len(payload) > ownedBusinessLimit {
		s.stop()
		return errOwnedPipe
	}
	if writeFrame(s.stream, payload) != nil {
		s.stop()
		return errOwnedPipe
	}
	return nil
}

func (s *ownedSession) sendResult(result []byte) {
	s.mu.Lock()
	if s.closed || !s.ready {
		s.mu.Unlock()
		return
	}
	generation := s.generation
	s.mu.Unlock()
	if len(result) == 0 || !json.Valid(result) {
		s.stop()
		return
	}
	payload, err := json.Marshal(struct {
		Protocol   int             `json:"protocol"`
		Generation int64           `json:"generation"`
		Result     json.RawMessage `json:"result"`
	}{1, generation, result})
	if err != nil {
		s.stop()
		return
	}
	_ = s.write(payload, false)
}

func (s *ownedSession) serve() error {
	defer s.stop()
	// time.Now的单调分量随Add保留；timer只唤醒，不作为成功授权证据。
	deadline := s.now().Add(s.budget)
	s.mu.Lock()
	s.handshakeDeadline = deadline
	s.mu.Unlock()
	go s.readWorker()
	timer := time.NewTimer(s.budget)
	defer timer.Stop()
	hello, err := s.read(ownedHandshakeLimit, timer.C, deadline)
	if err != nil {
		return errOwnedPipe
	}
	fields, err := ownedObject(hello, "type", "protocol", "generation")
	if err != nil {
		return errOwnedPipe
	}
	var kind string
	if json.Unmarshal(fields["type"], &kind) != nil || kind != "hello" {
		return errOwnedPipe
	}
	generation, err := ownedGeneration(fields)
	if err != nil || !s.now().Before(deadline) {
		return errOwnedPipe
	}
	s.mu.Lock()
	s.generation = generation
	s.mu.Unlock()
	ack, _ := json.Marshal(struct {
		Type       string `json:"type"`
		Protocol   int    `json:"protocol"`
		Generation int64  `json:"generation"`
	}{"ack", 1, generation})
	ackDone := make(chan error, 1)
	go func() { ackDone <- s.write(ack, true) }()
	select {
	case err = <-ackDone:
		if err != nil || !s.now().Before(deadline) {
			return errOwnedPipe
		}
	case <-timer.C:
		return errOwnedPipe
	case <-s.done:
		return errOwnedPipe
	}
	s.mu.Lock()
	if s.closed || !s.now().Before(deadline) {
		s.mu.Unlock()
		return errOwnedPipe
	}
	s.ready = true
	s.mu.Unlock()
	timer.Stop()
	for {
		frame, err := s.read(ownedBusinessLimit, nil, time.Time{})
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return errOwnedPipe
		}
		envelope, err := ownedObject(frame, "protocol", "generation", "action")
		if err != nil {
			return errOwnedPipe
		}
		current, err := ownedGeneration(envelope)
		if err != nil || current != generation {
			return errOwnedPipe
		}
		actionFields, err := ownedObject(envelope["action"], "id", "method", "data")
		if err != nil {
			return errOwnedPipe
		}
		action := &Action{}
		if json.Unmarshal(envelope["action"], action) != nil || action.Id == "" || action.Method == "" {
			return errOwnedPipe
		}
		_ = actionFields // 保留既有data形态，由业务处理器解释。
		result := ActionResult{Id: action.Id, Method: action.Method, ownedSend: s.sendResult}
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return errOwnedPipe
		}
		if s.control != nil && ownedLifecycleMethod(action.Method) {
			result.ownedControl = s.control.admitLocked(generation)
			if result.ownedControl == nil {
				s.mu.Unlock()
				// 准入预算耗尽即撤销整个owned会话，不创建额外阻塞发送任务。
				return errOwnedPipe
			}
		}
		// 已准入任务可能持续到进程退出；不虚称旧业务均支持context取消。
		go func() {
			defer func() {
				if recover() != nil {
					s.stop()
				}
			}()
			s.dispatch(action, result)
		}()
		s.mu.Unlock()
	}
}
