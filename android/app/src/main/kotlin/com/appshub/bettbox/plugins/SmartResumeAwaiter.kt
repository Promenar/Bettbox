package com.appshub.bettbox.plugins

internal data class SmartResumeOrigin(val intent: VpnIntentController.Intent, val wasSmartStopped: Boolean) {
    fun preserveOnCleanup(currentFlag: Boolean): Boolean = wasSmartStopped || currentFlag
}

internal data class SmartResumeObservation<T>(val pending: Boolean, val receipt: T? = null)

// 请求接受与启动完成分开；等待只消费同一请求的快照，超时不能确认成功。
internal suspend fun <T> awaitSmartResumeReceipt(
    attempts: Int,
    snapshot: () -> SmartResumeObservation<T>,
    pause: suspend () -> Unit,
): T? {
    require(attempts > 0)
    repeat(attempts) { index ->
        val state = snapshot()
        state.receipt?.let { return it }
        if (!state.pending) return null
        if (index + 1 < attempts) pause()
    }
    return null
}

// 完成前的前台收尾与生命周期快照使用同一状态决策。
internal fun <T> smartResumeSnapshot(
    currentIntent: Boolean,
    phase: VpnLifecycle.Phase,
    runningPublished: Boolean,
    pendingPublished: Boolean,
    startRequested: Boolean,
    suspended: Boolean,
    receipt: () -> T,
): SmartResumeObservation<T> {
    if (!currentIntent) return SmartResumeObservation(false)
    if (phase == VpnLifecycle.Phase.RUNNING && runningPublished && !suspended) {
        return SmartResumeObservation(false, receipt())
    }
    if (startRequested || phase == VpnLifecycle.Phase.STARTING ||
        (phase == VpnLifecycle.Phase.RUNNING && pendingPublished)) {
        return SmartResumeObservation(true)
    }
    return SmartResumeObservation(false)
}
