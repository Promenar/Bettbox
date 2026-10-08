package state

import (
	"encoding/json"
	"errors"
	"sync"
)

var stateMu sync.RWMutex

func cloneStrings(values []string) []string {
	if values == nil {
		return nil
	}
	copyOf := make([]string, len(values))
	copy(copyOf, values)
	return copyOf
}

func cloneState(value State) State {
	value.BypassDomain = cloneStrings(value.BypassDomain)
	if source := value.VpnProps.AccessControl; source != nil {
		control := *source
		control.AcceptList = cloneStrings(source.AcceptList)
		control.RejectList = cloneStrings(source.RejectList)
		value.VpnProps.AccessControl = &control
	}
	return value
}

// Snapshot只返回调用者持有的副本，避免列表和指针泄露共享可变状态。
func Snapshot() State {
	stateMu.RLock()
	defer stateMu.RUnlock()
	return cloneState(currentState)
}

// Copy返回显式状态的深副本。
func Copy(value State) State {
	return cloneState(value)
}

// MergeJSON基于调用方给出的显式快照执行部分合并，不读取或提交全局状态。
func MergeJSON(base State, data []byte) (State, error) {
	next := cloneState(base)
	if json.Unmarshal(data, &next) != nil {
		return State{}, errors.New("客户端状态格式无效")
	}
	return Copy(next), nil
}

// Replace提交调用方持有的状态副本，不保留任何可变别名。
func Replace(value State) {
	stateMu.Lock()
	defer stateMu.Unlock()
	currentState = cloneState(value)
}

// ApplyJSON保留有效部分更新；解析失败不提交任何字段或输入内容。
func ApplyJSON(data []byte) error {
	stateMu.Lock()
	defer stateMu.Unlock()
	next, err := MergeJSON(currentState, data)
	if err != nil {
		return err
	}
	currentState = next
	return nil
}
