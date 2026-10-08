package android.content

import android.os.PowerManager

abstract class BroadcastReceiver {
    abstract fun onReceive(context: Context?, intent: Intent?)
}

class Intent(val action: String?) {
    companion object {
        const val ACTION_SCREEN_ON = "android.intent.action.SCREEN_ON"
        const val ACTION_SCREEN_OFF = "android.intent.action.SCREEN_OFF"
    }
}

class IntentFilter {
    val actions = mutableSetOf<String>()

    fun addAction(action: String) {
        actions.add(action)
    }
}

// 保存真实生产接收器；事件通过公开 onReceive 入口送达。
class Context(val powerManager: PowerManager = PowerManager()) {
    var registerCalls = 0
        private set
    var unregisterCalls = 0
        private set
    var unregisterFailures = 0
    private var receiver: BroadcastReceiver? = null
    private var filter: IntentFilter? = null

    val receiverRegistered: Boolean get() = receiver != null

    fun registerReceiver(receiver: BroadcastReceiver, filter: IntentFilter): Intent? {
        check(this.receiver == null) { "接收器重复注册" }
        registerCalls += 1
        this.receiver = receiver
        this.filter = filter
        return null
    }

    fun unregisterReceiver(receiver: BroadcastReceiver) {
        unregisterCalls += 1
        check(this.receiver === receiver) { "注销目标不匹配" }
        if (unregisterFailures > 0) {
            unregisterFailures -= 1
            throw IllegalStateException()
        }
        this.receiver = null
        filter = null
    }

    fun dispatch(action: String) {
        val target = checkNotNull(receiver) { "没有已注册接收器" }
        check(filter?.actions?.contains(action) == true) { "广播不在注册范围内" }
        target.onReceive(this, Intent(action))
    }
}
