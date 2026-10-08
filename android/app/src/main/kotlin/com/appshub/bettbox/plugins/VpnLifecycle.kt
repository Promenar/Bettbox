package com.appshub.bettbox.plugins

// 所有方法由调用方的短状态锁保护，原生调用使用独立串行锁。
internal class VpnLifecycle<S : Any> {
    enum class Phase { IDLE, STARTING, RUNNING, STOPPING, SUSPENDED, BLOCKED }
    data class Ticket<S>(val generation: Long, val service: S)
    var generation = 0L
        private set
    var phase = Phase.IDLE
        private set
    var ticket: Ticket<S>? = null
        private set

    fun begin(service: S): Ticket<S>? {
        if (phase != Phase.IDLE && phase != Phase.SUSPENDED) return null
        return Ticket(++generation, service).also {
            ticket = it
            phase = Phase.STARTING
        }
    }

    fun current(value: Ticket<S>): Boolean = ticket == value && generation == value.generation

    fun started(value: Ticket<S>): Boolean {
        if (!current(value) || phase != Phase.STARTING) return false
        phase = Phase.RUNNING
        return true
    }

    fun invalidate(): Long {
        ++generation
        phase = Phase.STOPPING
        return generation
    }

    fun stopped(stopGeneration: Long, success: Boolean, suspended: Boolean): Boolean {
        if (generation != stopGeneration) return false
        phase = if (!success) Phase.BLOCKED else if (suspended) Phase.SUSPENDED else Phase.IDLE
        ticket = if (success && suspended) ticket?.let { Ticket(generation, it.service) } else null
        return success
    }

    fun failed(value: Ticket<S>, cleanupSucceeded: Boolean): Boolean {
        if (!current(value)) return false
        phase = if (cleanupSucceeded) Phase.IDLE else Phase.BLOCKED
        ticket = null
        return true
    }

    fun block() {
        ++generation
        phase = Phase.BLOCKED
        ticket = null
    }

    fun canPublish(service: S): Boolean = ticket?.service === service &&
        (phase == Phase.RUNNING || phase == Phase.SUSPENDED)

    fun publish(service: S, generation: Long, action: () -> Unit): Boolean {
        if (ticket?.generation != generation || !canPublish(service)) return false
        action()
        return true
    }
}
