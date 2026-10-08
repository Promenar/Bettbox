package com.appshub.bettbox.plugins

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

// 使用生产工作门禁卡住建立阶段，验证停止确认必须等待旧工作和输入收尾。
object VpnWorkGateFixture {
    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val gate = VpnWorkGate()
        val state = VpnLifecycle<Any>()
        val established = CompletableDeferred<Unit>()
        val releaseEstablish = CompletableDeferred<Unit>()
        val stopEntered = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        val a = checkNotNull(state.begin(Any()))
        val start = launch {
            gate.start(prepare = {
                established.complete(Unit)
                releaseEstablish.await()
                events.add("establishReturned")
            }, consume = {
                check(!state.current(a))
            }, finish = { events.add("inputClosed") })
        }
        established.await()
        val stopGeneration = state.invalidate()
        val stop = async {
            stopEntered.complete(Unit)
            gate.run {
                events.add("stopConfirmed")
                check(state.stopped(stopGeneration, success = true, suspended = false))
            }
        }
        stopEntered.await()
        yield()
        val stoppedTooEarly = stop.isCompleted
        val bAcceptedTooEarly = state.begin(Any()) != null
        releaseEstablish.complete(Unit)
        start.join()
        stop.await()
        check(!stoppedTooEarly) { "旧 establish 未完成时已经确认停止" }
        check(!bAcceptedTooEarly) { "旧启动工作未收尾时已经接纳新代" }
        check(events.indexOf("inputClosed") < events.indexOf("stopConfirmed"))
        checkNotNull(state.begin(Any()))
        recoveryWaitsAndRejectsRevokedIntent()
        inputCloseFailureCannotBeClearedByOldStop()
        println("VPN work gate fixture passed")
    }

    private suspend fun recoveryWaitsAndRejectsRevokedIntent() = kotlinx.coroutines.coroutineScope {
        val gate = VpnWorkGate()
        val intents = VpnIntentController()
        val a = intents.request()
        val stopping = CompletableDeferred<Unit>()
        val releaseStop = CompletableDeferred<Unit>()
        var resumed = false
        val recovery = launch {
            gate.recover(current = { intents.current(a) }, stop = {
                stopping.complete(Unit)
                releaseStop.await()
                true
            }, commit = {
                resumed = intents.recovered(a, it) == VpnIntentController.Recovery.READY
            })
        }
        stopping.await()
        intents.cancel()
        val b = intents.request()
        releaseStop.complete(Unit)
        recovery.join()
        check(!resumed)
        var nativeStopCalls = 0
        gate.recover(current = { intents.current(a) }, stop = { ++nativeStopCalls; true }, commit = { error("旧意图不得提交恢复") })
        check(nativeStopCalls == 0)
        gate.recover(current = { intents.current(b) }, stop = { ++nativeStopCalls; true }, commit = {
            resumed = intents.recovered(b, it) == VpnIntentController.Recovery.READY
        })
        check(resumed && nativeStopCalls == 1)
    }

    private suspend fun inputCloseFailureCannotBeClearedByOldStop() = kotlinx.coroutines.coroutineScope {
        val gate = VpnWorkGate()
        val state = VpnLifecycle<Any>()
        checkNotNull(state.begin(Any()))
        val establishing = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val start = launch {
            gate.start(prepare = { establishing.complete(Unit); release.await() }, consume = {}, finish = { state.block() })
        }
        establishing.await()
        val stopGeneration = state.invalidate()
        val stop = async {
            gate.run { check(!state.stopped(stopGeneration, true, false)) }
        }
        yield()
        check(!stop.isCompleted)
        release.complete(Unit)
        start.join()
        stop.await()
        check(state.phase == VpnLifecycle.Phase.BLOCKED)
        check(state.begin(Any()) == null)
    }
}
