package com.appshub.bettbox.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.appshub.bettbox.GlobalState

class PackageReplacedReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "PackageReplacedReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val pending = goAsync()
        try {
            if (Build.VERSION.SDK_INT >= 36) {
                GlobalState.handlePackageReplacement()
            } else {
                android.net.VpnService.prepare(context)
            }
        } catch (_: Exception) {
            Log.e(TAG, "更新恢复请求未确认")
        } finally {
            pending.finish()
        }
    }
}
