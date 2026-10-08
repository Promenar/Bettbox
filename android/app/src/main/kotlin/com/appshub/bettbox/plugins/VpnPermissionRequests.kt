package com.appshub.bettbox.plugins

import java.util.concurrent.atomic.AtomicInteger

// 由Activity主线程调用；同一系统弹窗共享结果，每个弹窗使用进程内唯一请求码。
class VpnPermissionRequests(private val nextCode: () -> Int? = ::allocateCode) {
    private data class Pending(val code: Int, val completions: MutableList<(Boolean) -> Unit>)
    private var pending: Pending? = null

    fun request(prepare: () -> Boolean, launch: (Int) -> Boolean, completion: (Boolean) -> Unit) {
        pending?.let { it.completions.add(completion); return }
        val required = try { prepare() } catch (_: Exception) { complete(listOf(completion), false); return }
        if (!required) { complete(listOf(completion), true); return }
        val code = nextCode() ?: run { complete(listOf(completion), false); return }
        pending = Pending(code, mutableListOf(completion))
        val launched = try { launch(code) } catch (_: Exception) { false }
        if (!launched) result(code, false)
    }

    fun result(code: Int, granted: Boolean): Boolean {
        val captured = pending ?: return false
        if (captured.code != code) return false
        pending = null
        complete(captured.completions, granted)
        return true
    }

    fun cancel() {
        val captured = pending ?: return
        pending = null
        complete(captured.completions, false)
    }

    private fun complete(completions: List<(Boolean) -> Unit>, granted: Boolean) {
        // 先移除归属，再回调；单个调用者异常不能遗失其余请求的完成结果。
        completions.forEach { try { it(granted) } catch (_: Exception) {} }
    }

    companion object {
        private val codes = AtomicInteger(0x4000)
        private fun allocateCode(): Int? {
            val code = codes.getAndIncrement()
            return code.takeIf { it in 0x4000..0x7fff }
        }
    }
}
