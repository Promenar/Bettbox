package com.appshub.bettbox.plugins

// 共享生产控制器，验证代际提交、绑定回调与恢复意图；Android 行为由设备验收覆盖。
object VpnLifecycleFixture {
    @JvmStatic
    fun main(args: Array<String>) {
        staleGenerationCannotMutateNotification()
        failedStopAndInputCleanupBlockStart()
        bindingEpochRejectsOldCallbacks()
        recoveryPreservesOnlyCurrentIntent()
        smartResumeWaitsAndRejectsTerminalState()
        failedResumeCleanupRetainsSuspendedRetry()
        timeoutAfterRunningRetainsOrigin()
        failedBeforeReceiptRetainsRequestOrigin()
        resumeForegroundPendingSnapshot()
        initialForegroundRequiresActualPublication()
        println("VPN lifecycle fixture passed")
    }

    private fun staleGenerationCannotMutateNotification() {
        val state = VpnLifecycle<Any>()
        val reusedService = Any()
        val a = checkNotNull(state.begin(reusedService))
        check(state.started(a))
        val stop = state.invalidate()
        check(state.stopped(stop, true, false))
        val b = checkNotNull(state.begin(reusedService))
        check(state.started(b))
        var cache = "B"
        check(!state.publish(reusedService, a.generation) { cache = "A" })
        check(cache == "B")
        check(!state.started(a))
        check(!state.failed(a, true))
        check(state.publish(reusedService, b.generation) { cache = "B committed" })
        check(cache == "B committed")
    }

    private fun failedStopAndInputCleanupBlockStart() {
        val state = VpnLifecycle<Any>()
        val a = checkNotNull(state.begin(Any()))
        check(!state.canPublish(a.service))
        check(state.failed(a, false))
        check(state.begin(Any()) == null)
        val stop = state.invalidate()
        check(!state.stopped(stop, false, false))
        check(state.phase == VpnLifecycle.Phase.BLOCKED)
        check(state.begin(Any()) == null)
        state.block()
        check(!state.stopped(stop, true, false))
        check(state.begin(Any()) == null)
    }

    private fun bindingEpochRejectsOldCallbacks() {
        val intents = VpnIntentController()
        val a = intents.request()
        val bindingA = checkNotNull(intents.beginBinding(a, true))
        intents.cancel()
        val b = intents.request()
        val bindingB = checkNotNull(intents.beginBinding(b, false))
        check(!intents.current(a))
        check(!intents.current(bindingA))
        check(!intents.registered(bindingA))
        check(intents.registered(bindingB))
        check(intents.isRegistered(bindingB))
        check(intents.current(b))
        intents.cancelIntent()
        val resumed = intents.request()
        check(intents.current(bindingB))
        check(intents.current(resumed))
        check(!intents.current(b))
    }

    private fun recoveryPreservesOnlyCurrentIntent() {
        val intents = VpnIntentController()
        val a = intents.request()
        check(intents.recovered(a, true) == VpnIntentController.Recovery.READY)
        check(intents.recovered(a, false) == VpnIntentController.Recovery.FAILED)
        intents.cancel()
        val b = intents.request()
        check(intents.recovered(a, true) == VpnIntentController.Recovery.CANCELLED)
        check(intents.recovered(a, false) == VpnIntentController.Recovery.CANCELLED)
        check(intents.recovered(b, true) == VpnIntentController.Recovery.READY)
    }
    private fun smartResumeWaitsAndRejectsTerminalState() = kotlinx.coroutines.runBlocking {
        var polls = 0
        var pauses = 0
        val receipt = awaitSmartResumeReceipt(4, snapshot = {
            polls++
            if (polls == 3) SmartResumeObservation(false, "same-intent-generation")
            else SmartResumeObservation(true)
        }, pause = { pauses++ })
        check(receipt == "same-intent-generation" && polls == 3 && pauses == 2)
        polls = 0
        check(awaitSmartResumeReceipt<String>(4, snapshot = {
            polls++
            SmartResumeObservation(false)
        }, pause = { error("终态不能等待") }) == null && polls == 1)
        pauses = 0
        check(awaitSmartResumeReceipt<String>(3, snapshot = {
            SmartResumeObservation(true)
        }, pause = { pauses++ }) == null && pauses == 2)
        val intents = VpnIntentController()
        val stale = intents.request()
        intents.cancel()
        intents.request()
        check(awaitSmartResumeReceipt<String>(3, snapshot = {
            if (intents.current(stale)) SmartResumeObservation(false, "stale")
            else SmartResumeObservation(false)
        }, pause = { error("过期不能等待") }) == null)
    }

    private fun failedResumeCleanupRetainsSuspendedRetry() {
        val state = VpnLifecycle<Any>()
        val initial = checkNotNull(state.begin(Any()))
        check(state.started(initial))
        check(state.stopped(state.invalidate(), true, true))
        val failedResume = checkNotNull(state.begin(Any()))
        check(state.failed(failedResume, true))
        val cleanup = state.invalidate()
        check(state.stopped(cleanup, true, true))
        check(state.phase == VpnLifecycle.Phase.SUSPENDED)
        val retry = checkNotNull(state.begin(Any()))
        check(retry.generation > failedResume.generation)
        check(state.started(retry))
        check(!state.stopped(cleanup, true, true))
        check(state.phase == VpnLifecycle.Phase.RUNNING)
        check(state.stopped(state.invalidate(), true, false))
        check(state.phase == VpnLifecycle.Phase.IDLE)
    }

    private fun timeoutAfterRunningRetainsOrigin() = kotlinx.coroutines.runBlocking {
        val intents = VpnIntentController()
        val state = VpnLifecycle<Any>()
        val ticket = checkNotNull(state.begin(Any()))
        val origin = SmartResumeOrigin(intents.request(), true)
        var smartStopped = true
        val receipt = kotlinx.coroutines.withTimeoutOrNull(100L) {
            awaitSmartResumeReceipt<String>(2, snapshot = {
                SmartResumeObservation(true)
            }, pause = {
                check(state.started(ticket))
                smartStopped = false
                kotlinx.coroutines.delay(Long.MAX_VALUE)
            })
        }
        check(receipt == null && state.phase == VpnLifecycle.Phase.RUNNING)
        check(intents.current(origin.intent))
        val cleanup = state.invalidate()
        check(state.stopped(cleanup, true, origin.preserveOnCleanup(smartStopped)))
        check(state.phase == VpnLifecycle.Phase.SUSPENDED)
    }

    private fun failedBeforeReceiptRetainsRequestOrigin() {
        val intents = VpnIntentController()
        val resumed = intents.request(wasSmartStopped = true)
        check(intents.keepSmartStoppedAfterFailure(currentFlag = false))
        check(intents.acknowledgeStart(resumed))
        check(!intents.keepSmartStoppedAfterFailure(currentFlag = false))
        intents.cancel()
        val later = intents.request()
        check(!intents.acknowledgeStart(resumed))
        check(!intents.keepSmartStoppedAfterFailure(currentFlag = false))
        check(intents.current(later))
        check(intents.keepSmartStoppedAfterFailure(currentFlag = true))
    }

    private fun resumeForegroundPendingSnapshot() {
        fun snapshot(phase: VpnLifecycle.Phase, ready: Boolean, pending: Boolean,
                     current: Boolean = true, requested: Boolean = false) = smartResumeSnapshot(
            currentIntent = current, phase = phase, runningPublished = ready,
            pendingPublished = pending, startRequested = requested, suspended = false,
            receipt = { "same-intent-generation" },
        )
        check(snapshot(VpnLifecycle.Phase.STARTING, false, true).pending)
        val foreground = snapshot(VpnLifecycle.Phase.RUNNING, false, true)
        check(foreground.pending && foreground.receipt == null)
        val ready = snapshot(VpnLifecycle.Phase.RUNNING, true, false)
        check(!ready.pending && ready.receipt == "same-intent-generation")
        check(!snapshot(VpnLifecycle.Phase.RUNNING, true, false, current = false).pending)
        check(snapshot(VpnLifecycle.Phase.RUNNING, true, false, current = false).receipt == null)
        for (phase in listOf(VpnLifecycle.Phase.IDLE, VpnLifecycle.Phase.STOPPING, VpnLifecycle.Phase.BLOCKED)) {
            val terminal = snapshot(phase, false, true)
            check(!terminal.pending && terminal.receipt == null)
        }
    }

    private fun initialForegroundRequiresActualPublication() = kotlinx.coroutines.runBlocking {
        var basicCalls = 0
        // 熄屏抑制速度刷新时，首次前台仍须由基础通知发布。
        check(com.appshub.bettbox.services.confirmInitialForeground(true,
            publishSpeed = { false }, publishBasic = { basicCalls++; true }))
        check(basicCalls == 1) { "速度未发布时必须基础前台兜底" }
        basicCalls = 0
        check(com.appshub.bettbox.services.confirmInitialForeground(true,
            publishSpeed = { true }, publishBasic = { basicCalls++; false }))
        check(basicCalls == 0)
        check(!com.appshub.bettbox.services.confirmInitialForeground(true,
            publishSpeed = { false }, publishBasic = { false }))
        check(com.appshub.bettbox.services.confirmInitialForeground(false,
            publishSpeed = { error("未选择速度通知") }, publishBasic = { true }))
        var failed = false
        try {
            com.appshub.bettbox.services.confirmInitialForeground(false,
                publishSpeed = { false }, publishBasic = { error("平台发布失败") })
        } catch (_: IllegalStateException) { failed = true }
        check(failed)
        failed = false
        basicCalls = 0
        try {
            com.appshub.bettbox.services.confirmInitialForeground(true,
                publishSpeed = { error("速度通知构造失败") },
                publishBasic = { basicCalls++; true })
        } catch (_: IllegalStateException) { failed = true }
        check(failed && basicCalls == 0)
        // Core 已进入 RUNNING 后，前台失败仍须收回同代 ticket。
        val lifecycle = VpnLifecycle<Any>()
        val ticket = checkNotNull(lifecycle.begin(Any()))
        check(lifecycle.started(ticket))
        check(lifecycle.failed(ticket, true))
        check(lifecycle.phase == VpnLifecycle.Phase.IDLE)
        check(!lifecycle.publish(ticket.service, ticket.generation) { error("失败 ticket 不可发布") })
        val replacement = checkNotNull(lifecycle.begin(Any()))
        check(!lifecycle.failed(ticket, false))
        check(lifecycle.current(replacement))
    }

}
