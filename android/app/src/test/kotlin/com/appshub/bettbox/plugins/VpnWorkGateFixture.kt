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
        check(!VpnWorkGate().stop({ true }, { false }, { it })) { "关闭失败不能返回停止成功" }
        stopResponseWaitsForCloseAndCommit()
        smartStopRetainsFailureAndWaitsForSuspension()
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

    private suspend fun smartStopRetainsFailureAndWaitsForSuspension() = kotlinx.coroutines.coroutineScope {
        for (closed in listOf(false, true)) {
            val state = VpnLifecycle<Any>()
            val ticket = checkNotNull(state.begin(Any()))
            check(state.started(ticket))
            val generation = state.invalidate()
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            var smartStopped = false
            val reply = async {
                VpnWorkGate().stop({ state.generation == generation }, {
                    entered.complete(Unit); release.await(); closed
                }, {
                    val committed = state.stopped(generation, it, suspended = true)
                    if (committed) smartStopped = true
                    committed
                })
            }
            entered.await()
            check(!reply.isCompleted && !smartStopped)
            release.complete(Unit)
            check(reply.await() == closed && smartStopped == closed)
            check(state.phase == if (closed) VpnLifecycle.Phase.SUSPENDED else VpnLifecycle.Phase.BLOCKED)
            check((state.begin(Any()) != null) == closed)
        }
    }

    private suspend fun stopResponseWaitsForCloseAndCommit() = kotlinx.coroutines.coroutineScope {
        val gate = VpnWorkGate()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var committed = false
        val reply = async {
            gate.stop({ true }, {
                entered.complete(Unit)
                release.await()
                true
            }, { closed -> committed = closed; closed })
        }
        entered.await()
        check(!reply.isCompleted && !committed)
        release.complete(Unit)
        check(reply.await() && committed)
        var calls = 0
        check(!gate.stop({ false }, { calls++; true }, { error("旧停止不能提交") }))
        check(calls == 0)
        var failureCommitted = false
        check(!gate.stop({ true }, { throw IllegalStateException("公开替身关闭失败") }, {
            failureCommitted = !it
            it
        }))
        check(failureCommitted)
        val state = VpnLifecycle<Any>()
        val a = checkNotNull(state.begin(Any()))
        check(state.started(a))
        val oldStop = state.invalidate()
        val closeEntered = CompletableDeferred<Unit>()
        val closeReleased = CompletableDeferred<Unit>()
        val oldReply = async {
            gate.stop({ state.generation == oldStop }, {
                closeEntered.complete(Unit); closeReleased.await(); true
            }, { state.stopped(oldStop, it, false) })
        }
        closeEntered.await()
        val newStop = state.invalidate()
        closeReleased.complete(Unit)
        check(!oldReply.await())
        check(state.phase == VpnLifecycle.Phase.STOPPING)
        check(gate.stop({ state.generation == newStop }, { true }, { state.stopped(newStop, it, false) }))
        check(state.phase == VpnLifecycle.Phase.IDLE)
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
