package com.appshub.bettbox.core

// 只模拟核心回执与调用记录；挂起决策由生产模块执行。
object Core {
    val calls = mutableListOf<Boolean>()
    private val responses = ArrayDeque<Boolean>()

    fun reset() {
        calls.clear()
        responses.clear()
    }

    fun respond(vararg accepted: Boolean) {
        responses.addAll(accepted.toList())
    }

    fun suspended(value: Boolean): Boolean {
        calls.add(value)
        return if (responses.isEmpty()) true else responses.removeFirst()
    }
}
