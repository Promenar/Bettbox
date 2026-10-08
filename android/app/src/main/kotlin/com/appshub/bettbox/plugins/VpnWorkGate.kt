package com.appshub.bettbox.plugins

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class VpnWorkGate {
    private val mutex = Mutex()

    suspend fun run(action: suspend () -> Unit) = mutex.withLock { action() }

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
