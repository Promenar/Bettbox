package main

import "sync/atomic"

// 能力只能在owned会话准入后注入，发送函数及请求字段均不能构造它。
type ownedListenerCapability interface{ handle(*Action, ActionResult) }

var ownedListenerMode atomic.Bool

func ownedHttpMethod(method Method) bool {
	return method == ownedHttpStartMethod || method == ownedHttpStopMethod || method == ownedHttpGetMethod
}
func ownedLifecycleMethod(method Method) bool {
	return ownedHttpMethod(method) || method == initClashMethod || method == setupConfigMethod ||
		method == updateConfigMethod || method == shutdownMethod || method == startListenerMethod || method == stopListenerMethod
}
