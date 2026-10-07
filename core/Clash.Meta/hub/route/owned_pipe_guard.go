package route

import "sync/atomic"

var ownedPipeMode atomic.Bool

// EnableOwnedPipeGuard只能收紧本进程；配置和订阅不能解除。
func EnableOwnedPipeGuard() { ownedPipeMode.Store(true) }
