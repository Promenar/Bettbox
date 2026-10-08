package com.appshub.bettbox.plugins

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class VpnWorkGate {
    private val mutex = Mutex()

    suspend fun run(action: suspend () -> Unit) = mutex.withLock { action() }

    // 返回值来自同次串行关闭与状态提交；旧票据不执行关闭，异常不能变成成功。
    suspend fun stop(current: () -> Boolean, close: suspend () -> Boolean, commit: (Boolean) -> Boolean): Boolean = mutex.withLock {
        if (!current()) return@withLock false
        val closed = try { close() } catch (_: Throwable) { false }
        commit(closed)
    }

    suspend fun recover(current: () -> Boolean, stop: suspend () -> Boolean, commit: (Boolean) -> Unit) {
        run {
            if (current()) commit(stop())
        }
    }

    suspend fun start(prepare: suspend () -> Unit, consume: suspend () -> Unit, finish: () -> Unit) {
        run {
            try {
                prepare()
                consume()
            } finally {
                finish()
            }
        }
    }
}
