package androidstartup

// TunOwnership是调用方已核验的值身份，State不发行generation或配置版本。
type TunOwnership struct{ Epoch, ConfigRevision, Generation int64 }

func (o TunOwnership) valid() bool { return o.Epoch > 0 && o.ConfigRevision > 0 && o.Generation > 0 }
func (s *State) setOwnerLocked(owner *TunOwnership) {
	if owner == nil {
		s.owner = nil
		return
	}
	copyOf := *owner
	s.owner = &copyOf
}

// 受管启动仅接纳已收口的State；拒绝输入不隐式替换当前资源。
func (s *State) StartOwnedWithInputCleanupReport(owner TunOwnership, fd int, ready bool, release func(), open func(*OnceLease) (Resource, error), cleanup func() error) StartReport {
	return s.startWithOwnershipReport(&owner, fd, ready, release, open, cleanup)
}

// StopOwned以当前资源完整身份为准；错代和旧Boolean旁路都不能停止新代。
type OwnedStopReport struct {
	Stopped         bool
	Matched         bool
	Blocked         bool
	Ownership       TunOwnership
	HasOwnership    bool
	Running         bool
	RetainsResource bool
	RetainsLease    bool
	Code            string
}

// 结果和剩余责任在同一状态锁内捕获，不能bool完成后再拼接后来快照。
func (s *State) StopOwnedReport(owner TunOwnership) OwnedStopReport {
	s.mu.Lock()
	defer s.mu.Unlock()
	matched := owner.valid() && s.owner != nil && *s.owner == owner
	stopped := false
	if matched {
		stopped = s.stopLocked()
	}
	report := OwnedStopReport{Stopped: stopped, Matched: matched, Blocked: s.blockedCode != "", Running: !s.runtime.IsZero(), RetainsResource: s.resource != nil, RetainsLease: s.lease != nil || len(s.pendingLeases) != 0, Code: s.blockedCode}
	if s.owner != nil {
		report.Ownership = *s.owner
		report.HasOwnership = true
	}
	return report
}
func (s *State) StopOwned(owner TunOwnership) bool { return s.StopOwnedReport(owner).Stopped }

func (s *State) OwnedIdentity() (TunOwnership, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.owner == nil {
		return TunOwnership{}, false
	}
	return *s.owner, true
}
