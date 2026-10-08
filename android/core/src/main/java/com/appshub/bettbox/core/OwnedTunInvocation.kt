package com.appshub.bettbox.core

import java.util.concurrent.atomic.AtomicBoolean

// 原生原始回执须由owner严格解码；输入快照只表达Kotlin的最终责任。
data class OwnedTunCall(val receipt: String?, val input: TunFDSnapshot, val bridgeBlocked: Boolean)

object OwnedTunInvocation {
    fun start(lease: TunFDLease, blocked: AtomicBoolean, invoke: () -> String?): OwnedTunCall {
        var receipt: String? = null
        try {
            if (!blocked.get()) receipt = invoke()
        } catch (_: Throwable) {
            // 不暴露原始异常；调用可能已进入原生副作用。
        } finally {
            if (!lease.closeUnclaimed()) blocked.set(true)
        }
        if (receipt == null) blocked.set(true)
        return OwnedTunCall(receipt, lease.snapshot(), blocked.get())
    }
}
