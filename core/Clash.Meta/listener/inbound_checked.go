package listener

import (
	"errors"
	"reflect"
	"sort"

	C "github.com/metacubex/mihomo/constant"
)

// 与 inboundListeners 一同受 inboundMux 保护；只有显式关闭确认可解除未知责任。
var inboundUnconfirmed = map[string]bool{}
var errInboundApplyUnconfirmed = errors.New("命名监听应用未确认")

func listenInboundChecked(value C.InboundListener, tunnel C.Tunnel) (err error) {
	defer func() {
		if recover() != nil {
			err = errInboundApplyUnconfirmed
		}
	}()
	if value.Listen(tunnel) != nil {
		return errInboundApplyUnconfirmed
	}
	return nil
}

// PatchInboundListenersChecked 保留部分创建和关闭失败的对象，不能证明协议内部任务已退出。
func PatchInboundListenersChecked(newListenerMap map[string]C.InboundListener, tunnel C.Tunnel, dropOld bool) error {
	inboundMux.Lock()
	defer inboundMux.Unlock()
	for name := range inboundListeners {
		if inboundUnconfirmed[name] {
			return errInboundApplyUnconfirmed
		}
	}
	// 当前协议均使用指针对象；先拒绝无效候选，避免在处理后续候选时丢失已进入的责任。
	// 先按对象建立等价类，避免同一候选的多个名称被拆成不同真实对象。
	parents := map[C.InboundListener]C.InboundListener{}
	var root func(C.InboundListener) C.InboundListener
	root = func(value C.InboundListener) C.InboundListener {
		parent, exists := parents[value]
		if !exists {
			parents[value] = value
			return value
		}
		if parent != value {
			parents[value] = root(parent)
		}
		return parents[value]
	}
	for name, value := range newListenerMap {
		if value == nil || reflect.ValueOf(value).Kind() != reflect.Pointer || reflect.ValueOf(value).IsNil() {
			return errInboundApplyUnconfirmed
		}
		root(value)
		if old, exists := inboundListeners[name]; exists {
			equal, err := inboundConfigEqual(old, value)
			if err != nil {
				return err
			}
			if equal {
				parents[root(value)] = root(old)
			}
		}
	}
	// 每个等价类优先沿用已运行对象，排序让多对象归并选择稳定。
	names := make([]string, 0, len(inboundListeners))
	for name := range inboundListeners {
		names = append(names, name)
	}
	sort.Strings(names)
	canonical := map[C.InboundListener]C.InboundListener{}
	for _, name := range names {
		value := inboundListeners[name]
		key := root(value)
		if _, exists := canonical[key]; !exists {
			canonical[key] = value
		}
	}
	effective := map[string]C.InboundListener{}
	desired := map[C.InboundListener]bool{}
	for name, value := range newListenerMap {
		key := root(value)
		if selected, exists := canonical[key]; exists {
			value = selected
		} else {
			canonical[key] = value
		}
		effective[name] = value
		desired[value] = true
	}
	if !dropOld {
		for name, value := range inboundListeners {
			if _, exists := effective[name]; !exists {
				desired[value] = true
			}
		}
	}
	started := map[C.InboundListener]bool{}
	for _, value := range inboundListeners {
		started[value] = true
	}
	r := &checkedCloseRound{results: make(map[checkedCloseIdentity]bool)}
	for name, value := range effective {
		if old, exists := inboundListeners[name]; exists {
			if old == value {
				continue
			}
			if !desired[old] {
				if !r.close(old) {
					inboundUnconfirmed[name] = true
					return errInboundApplyUnconfirmed
				}
				// 确认关闭是对象级事实；先移除全部旧别名，不能留给后续迭代。
				forgetInboundObjectLocked(old)
				delete(started, old)
			} else {
				delete(inboundListeners, name)
				delete(inboundUnconfirmed, name)
			}
		}
		// Listen 可先创建资源再失败或 panic，因此调用前就登记对象。
		inboundListeners[name] = value
		if started[value] {
			continue
		}
		inboundUnconfirmed[name] = true
		if err := listenInboundChecked(value, tunnel); err != nil {
			return err
		}
		delete(inboundUnconfirmed, name)
		started[value] = true
	}
	if dropOld {
		for _, name := range names {
			value, registered := inboundListeners[name]
			if !registered {
				continue
			}
			if _, exists := newListenerMap[name]; exists {
				continue
			}
			if desired[value] {
				delete(inboundListeners, name)
				delete(inboundUnconfirmed, name)
				continue
			}
			if !r.close(value) {
				inboundUnconfirmed[name] = true
				return errInboundApplyUnconfirmed
			}
			forgetInboundObjectLocked(value)
		}
	}
	return nil
}

func inboundConfigEqual(old, value C.InboundListener) (equal bool, err error) {
	defer func() {
		if recover() != nil {
			err = errInboundApplyUnconfirmed
		}
	}()
	return old.Config().Equal(value.Config()), nil
}

// 调用方持有 inboundMux；对象关闭已确认时一并移除所有名称责任。
func forgetInboundObjectLocked(value C.InboundListener) {
	for name, registered := range inboundListeners {
		if registered == value {
			delete(inboundListeners, name)
			delete(inboundUnconfirmed, name)
		}
	}
}
