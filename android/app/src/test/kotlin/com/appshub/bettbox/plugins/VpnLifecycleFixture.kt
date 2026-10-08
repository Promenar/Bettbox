package com.appshub.bettbox.plugins

// 共享生产控制器，验证代际提交、绑定回调与恢复意图；Android 行为由设备验收覆盖。
object VpnLifecycleFixture {
    @JvmStatic
    fun main(args: Array<String>) {
        staleGenerationCannotMutateNotification()
        failedStopAndInputCleanupBlockStart()
        bindingEpochRejectsOldCallbacks()
        recoveryPreservesOnlyCurrentIntent()
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
}
