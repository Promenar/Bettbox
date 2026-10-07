//go:build darwin && !cgo

package main

import (
	H "github.com/metacubex/mihomo/listener/http"
	"github.com/metacubex/mihomo/tunnel"
	"sync"
)

var ownedListenerInstallation struct {
	sync.Mutex
	owner *ownedListenerOwner
}

// 唯一生产注入点；任何既有owner都拒绝替换，错误引用保留至进程退出。
func installOwnedListener(s *ownedSession) error {
	ownedListenerInstallation.Lock()
	defer ownedListenerInstallation.Unlock()
	if ownedListenerInstallation.owner != nil {
		return errOwnedListener
	}
	owner := newOwnedListenerOwner(&s.mu, func() (ownedListenerResource, error) {
		listener, err := H.NewCredentialBlindLoopback(tunnel.Tunnel)
		if listener == nil {
			return nil, err
		}
		return listener, err
	}, func() bool {
		runLock.Lock()
		defer runLock.Unlock()
		return isInit && currentConfig != nil
	}, handleActionDirect)
	s.control = owner
	ownedListenerInstallation.owner = owner
	ownedListenerMode.Store(true)
	return nil
}
