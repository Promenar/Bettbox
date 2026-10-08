package androidstartup

// RejectedInputReport只描述本次未进入TUN构造的输入收尾。
// Blocked是State全局责任，不能由后续输入已清理覆盖。
type RejectedInputReport struct {
	InputCleanupConfirmed bool
	Blocked               bool
	RetainsInputLease     bool
	Code                  string
}

// RejectInputWithCleanup不调用stopLocked或open，保持既有连接资源和runtime。
// 输入FD关闭函数与回调release必须各负责自己的单次移交，不允许从回调重入State。
func (s *State) RejectInputWithCleanup(release func(), cleanup func() error) RejectedInputReport {
	s.mu.Lock()
	defer s.mu.Unlock()
	lease := NewOnceLease(release)
	cleanupErr, cleanupPanicked := callInputCleanup(cleanup)
	if cleanupErr != nil || cleanupPanicked {
		code := startCodeInputCleanupFailed
		if cleanupPanicked {
			code = startCodeInputCleanupPanic
		}
		if s.inputCleanupErr == nil {
			s.inputCleanupErr = cleanupErr
		}
		s.markBlockedLocked(code)
	}
	releasePanicked := releaseLease(lease)
	if releasePanicked {
		s.retainPendingLeaseLocked(lease)
		s.markBlockedLocked(startCodeReleasePanic)
	}
	return RejectedInputReport{
		InputCleanupConfirmed: cleanupErr == nil && !cleanupPanicked && !releasePanicked,
		Blocked:               s.blockedCode != "",
		RetainsInputLease:     releasePanicked,
		Code:                  s.blockedCode,
	}
}
