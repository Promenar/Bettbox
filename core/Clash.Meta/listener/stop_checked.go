package listener

import (
	"errors"
	"io"
	"reflect"
	"sync"
)

var checkedStopMux sync.Mutex
var errListenerCloseUnconfirmed = errors.New("监听关闭未确认")

type checkedCloseIdentity struct {
	kind    reflect.Type
	pointer uintptr
}

// 单轮按对象身份缓存结果；失败不在同一轮重试，后续轮次可显式重新关闭。
type checkedCloseRound struct {
	results map[checkedCloseIdentity]bool
	failed  bool
}

func (r *checkedCloseRound) close(value io.Closer) (ok bool) {
	if value == nil {
		return true
	}
	v := reflect.ValueOf(value)
	// 所有当前生产字段使用指针；typed nil 不调用其方法。
	if v.Kind() == reflect.Pointer && v.IsNil() {
		return true
	}
	if v.Kind() != reflect.Pointer {
		// 无稳定对象身份不能承诺去重；保留未知归属而非猜测已经关闭。
		r.failed = true
		return false
	}
	key := checkedCloseIdentity{v.Type(), v.Pointer()}
	if result, exists := r.results[key]; exists {
		return result
	}
	defer func() {
		if recover() != nil {
			ok = false
		}
		r.results[key] = ok
		if !ok {
			r.failed = true
		}
	}()
	ok = value.Close() == nil
	return ok
}

// 每组只持有其真实重建锁；不同时持有两个槽位锁，避免跨组锁序环。
func (r *checkedCloseRound) group(mu *sync.Mutex, work func()) {
	mu.Lock()
	defer mu.Unlock()
	work()
}

// StopListenerChecked 只确认已登记资源的 Close 返回值，不证明 accept/drain、
// provider/controller 或全部 TUN stack 已退出。旧 StopListener 行为保持不变。
func StopListenerChecked() error {
	checkedStopMux.Lock()
	defer checkedStopMux.Unlock()
	r := &checkedCloseRound{results: make(map[checkedCloseIdentity]bool)}
	r.group(&socksMux, func() {
		if r.close(socksListener) {
			socksListener = nil
		}
		if r.close(socksUDPListener) {
			socksUDPListener = nil
		}
	})
	r.group(&httpMux, func() {
		if r.close(httpListener) {
			httpListener = nil
		}
	})
	r.group(&redirMux, func() {
		if r.close(redirListener) {
			redirListener = nil
		}
		if r.close(redirUDPListener) {
			redirUDPListener = nil
		}
	})
	r.group(&tproxyMux, func() {
		if r.close(tproxyListener) {
			tproxyListener = nil
		}
		if r.close(tproxyUDPListener) {
			tproxyUDPListener = nil
		}
	})
	r.group(&mixedMux, func() {
		if r.close(mixedListener) {
			mixedListener = nil
		}
		if r.close(mixedUDPLister) {
			mixedUDPLister = nil
		}
	})
	r.group(&tunMux, func() {
		if r.close(tunLister) {
			tunLister = nil
		}
	})
	r.group(&ssMux, func() {
		if r.close(shadowSocksListener) {
			shadowSocksListener = nil
		}
	})
	r.group(&vmessMux, func() {
		if r.close(vmessListener) {
			vmessListener = nil
		}
	})
	r.group(&tuicMux, func() {
		if r.close(tuicListener) {
			tuicListener = nil
		}
	})
	r.group(&inboundMux, func() {
		for name, value := range inboundListeners {
			if r.close(value) {
				delete(inboundListeners, name)
			}
		}
	})
	r.group(&tunnelMux, func() {
		for name, value := range tunnelTCPListeners {
			if r.close(value) {
				delete(tunnelTCPListeners, name)
			}
		}
		for name, value := range tunnelUDPListeners {
			if r.close(value) {
				delete(tunnelUDPListeners, name)
			}
		}
	})
	if r.failed {
		return errListenerCloseUnconfirmed
	}
	return nil
}
