package com.appshub.bettbox.core

import androidx.annotation.Keep

// JNI 必须显式领取本代 FD；调用异常时 Kotlin 只收回尚未领取的资源。
@Keep
class TunFDLease(private val fd: Int, private val closeFD: (Int) -> Unit) {
    private var claimed = false
    private var closed = false
    private var cleanupFailed = false

    init {
        require(fd >= 0) { "无效的 TUN 描述符" }
    }

    @Synchronized
    fun peek(): Int = if (claimed || closed) -1 else fd

    @Synchronized
    fun claim(): Int {
        if (claimed || closed) return -1
        claimed = true
        return fd
    }

    @Synchronized
    fun closeUnclaimed(): Boolean {
        if (claimed || closed) return !cleanupFailed
        closed = true
        if (fd > 0) {
            try {
                closeFD(fd)
            } catch (_: Throwable) {
                // 不重试数字 FD，也不返回可能含身份信息的原始异常。
                cleanupFailed = true
            }
        }
        return !cleanupFailed
    }
}
