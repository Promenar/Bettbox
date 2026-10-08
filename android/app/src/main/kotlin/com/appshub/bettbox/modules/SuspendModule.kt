package com.appshub.bettbox.modules

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import androidx.core.content.getSystemService
import com.appshub.bettbox.core.Core

class SuspendModule(private val context: Context) {
    private var isInstalled = false
    private var isSuspended = false

    private val powerManager: PowerManager? by lazy { context.getSystemService<PowerManager>() }

    private val isScreenOn: Boolean get() = powerManager?.isInteractive ?: true

    private val isDeviceIdleMode: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && powerManager?.isDeviceIdleMode == true

    private val shouldSuspend: Boolean get() = !isScreenOn && isDeviceIdleMode

    private fun updateSuspendState() {
        val shouldSuspendNow = shouldSuspend

        when {
            shouldSuspendNow && !isSuspended -> {
                if (Core.suspended(true)) isSuspended = true
            }
            !shouldSuspendNow && isSuspended -> {
                if (Core.suspended(false)) {
                    isSuspended = false
                    com.appshub.bettbox.plugins.VpnPlugin.onUpdateNetwork()
                }
            }
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.action?.let { action ->
                if (action == Intent.ACTION_SCREEN_ON && isSuspended) {
                    if (Core.suspended(false)) isSuspended = false
                } else {
                    updateSuspendState()
                }
            }
        }
    }

    fun install() {
        if (isInstalled) return

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
        }
        context.registerReceiver(receiver, filter)
        isInstalled = true
        updateSuspendState()
    }

    fun uninstall(): Boolean {
        if (!isInstalled && !isSuspended) return true
        return try {
            if (isInstalled) {
                context.unregisterReceiver(receiver)
                isInstalled = false
            }
            if (isSuspended) {
                if (!Core.suspended(false)) return false
                isSuspended = false
            }
            true
        } catch (_: Exception) {
            // 保留未确认的注册责任；调用方不得提交清理成功。
            false
        }
    }
}
