package com.appshub.bettbox.plugins

// 启动意图和绑定回调均在短状态锁中检查，旧回调不能借用新意图。
internal class VpnIntentController {
    enum class Recovery { READY, CANCELLED, FAILED }
    data class Intent(val id: Long)
    data class Binding(val id: Long, val intent: Intent, val vpnEnabled: Boolean)
    private var sequence = 0L
    private var bindingSequence = 0L
    private var intent: Intent? = null
    private var binding: Binding? = null
    private var registered = false

    fun request(): Intent = Intent(++sequence).also { intent = it }
    fun current(value: Intent): Boolean = intent == value
    fun recovered(value: Intent, success: Boolean): Recovery =
        if (!current(value)) Recovery.CANCELLED else if (success) Recovery.READY else Recovery.FAILED
    fun current(value: Binding): Boolean = binding == value
    fun beginBinding(value: Intent, vpnEnabled: Boolean): Binding? {
        if (!current(value)) return null
        return Binding(++bindingSequence, value, vpnEnabled).also {
            binding = it
            registered = false
        }
    }
    fun registered(value: Binding): Boolean {
        if (!current(value)) return false
        registered = true
        return true
    }
    fun isRegistered(value: Binding): Boolean = binding == value && registered
    fun cancelIntent() { intent = null; ++sequence }
    fun cancel() {
        intent = null
        binding = null
        registered = false
        ++sequence
    }
}
