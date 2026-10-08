package com.appshub.bettbox.core

import androidx.annotation.Keep

enum class TunFDDisposition { UNCLAIMED, CLAIMED, RELEASED, UNKNOWN }

data class TunFDSnapshot(val disposition: TunFDDisposition)

// JNI 必须显式领取本代 FD；调用异常时 Kotlin 只收回尚未领取的资源。
@Keep
class TunFDLease(private val fd: Int, private val closeFD: (Int) -> Unit) {
    private var claimed = false
    private var closed = false
    private var closing = false
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

    // 领取状态只描述本地输入责任；CLAIMED不能证明Go已关闭输入。
    @Synchronized
    fun snapshot(): TunFDSnapshot = TunFDSnapshot(when {
        cleanupFailed -> TunFDDisposition.UNKNOWN
        closing -> TunFDDisposition.UNCLAIMED
        claimed -> TunFDDisposition.CLAIMED
        closed -> TunFDDisposition.RELEASED
        else -> TunFDDisposition.UNCLAIMED
    })

    @Synchronized
    fun closeUnclaimed(): Boolean {
        if (closing) return false
        if (claimed || closed) return !cleanupFailed
        // 先阻止再次领取；实际关闭完成前，重入不能取得成功证明。
        closed = true
        closing = true
        try {
            if (fd > 0) {
                closeFD(fd)
            }
        } catch (_: Throwable) {
            // 不重试数字 FD，也不返回可能含身份信息的原始异常。
            cleanupFailed = true
        } finally {
            closing = false
        }
        return !cleanupFailed
    }
}
