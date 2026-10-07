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

// ApplyJSON保留有效部分更新；解析失败不提交任何字段或输入内容。
func ApplyJSON(data []byte) error {
	stateMu.Lock()
	defer stateMu.Unlock()
	next := cloneState(currentState)
	if json.Unmarshal(data, &next) != nil {
		return errors.New("客户端状态格式无效")
	}
	currentState = next
	return nil
}
