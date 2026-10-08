package com.appshub.bettbox

// 调用方持有GlobalState.runLock；engine与messenger均按对象身份匹配。
class ServiceRuntimeAdmission<T : Any> {
    private var rejected: T? = null

    fun reject(current: T?, sender: Any, messenger: (T) -> Any): Boolean {
        if (current == null || messenger(current) !== sender) return false
        rejected = current
        return true
    }

    fun isRejected(current: T?): Boolean = current != null && rejected === current
    fun clear() { rejected = null }
}
