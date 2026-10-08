package listener

// HasListenerResponsibility 检查登记槽位，不关闭未知资源，也不证明线程已退出。
// 核心首次 owner 在自身配置锁内使用；各槽位采用既有重建锁。
func HasListenerResponsibility() bool {
	checkedStopMux.Lock()
	defer checkedStopMux.Unlock()
	present := false
	r := &checkedCloseRound{}
	r.group(&socksMux, func() { present = present || socksListener != nil || socksUDPListener != nil })
	r.group(&httpMux, func() { present = present || httpListener != nil })
	r.group(&redirMux, func() { present = present || redirListener != nil || redirUDPListener != nil })
	r.group(&tproxyMux, func() { present = present || tproxyListener != nil || tproxyUDPListener != nil })
	r.group(&mixedMux, func() { present = present || mixedListener != nil || mixedUDPLister != nil })
	r.group(&tunMux, func() { present = present || tunLister != nil })
	r.group(&ssMux, func() { present = present || shadowSocksListener != nil })
	r.group(&vmessMux, func() { present = present || vmessListener != nil })
	r.group(&tuicMux, func() { present = present || tuicListener != nil })
	r.group(&inboundMux, func() { present = present || len(inboundListeners) != 0 })
	r.group(&tunnelMux, func() { present = present || len(tunnelTCPListeners) != 0 || len(tunnelUDPListeners) != 0 })
	return present
}
