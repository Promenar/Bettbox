package com.appshub.bettbox.plugins

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.appshub.bettbox.core.Core
import com.appshub.bettbox.NativeRuntimeIdentity
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.RunState
import com.appshub.bettbox.models.VpnOptions
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var messenger: BinaryMessenger

    companion object {
        private val activeChannels = CopyOnWriteArrayList<MethodChannel>()
        private val mainHandler = Handler(Looper.getMainLooper())
        private val identityScope = CoroutineScope(Dispatchers.Default + SupervisorJob())

        internal fun confirmRuntimeIdentity(result: MethodChannel.Result, expected: Any?, current: () -> Boolean) {
            identityScope.launch {
                val confirmed = NativeRuntimeIdentity.confirm(expected) { Core.ownedConfigStatusRaw() }
                withContext(Dispatchers.Main) {
                    runCatching { result.success(confirmed && current()) }
                        .onFailure { Log.e(TAG, "身份回执投递失败") }
                }
            }
        }

        private val gson = Gson()
        private const val TAG = "ServicePlugin"

        private fun notify(method: String) {
            mainHandler.post {
                activeChannels.forEach { ch ->
                    runCatching { ch.invokeMethod(method, null) }
                        .onFailure { Log.e(TAG, "$method notify error: ${it.message}") }
                }
            }
        }

        fun notifyNetworkChanged() = notify("networkChanged")
        fun notifyQuickResponse() = notify("quickResponse")
        fun notifyVpnStartFailed() = notify("vpnStartFailed")
        fun notifyRunStateChanged(state: RunState) {
            mainHandler.post {
                activeChannels.forEach { ch ->
                    runCatching { ch.invokeMethod("runStateChanged", state.name) }
                        .onFailure { Log.e(TAG, "runStateChanged notify error: ${it.message}") }
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        messenger = binding.binaryMessenger
        channel = MethodChannel(binding.binaryMessenger, "service").apply {
            setMethodCallHandler(this@ServicePlugin)
        }
        activeChannels.add(channel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        activeChannels.remove(channel)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "runtimeIdentityFailed" -> result.success(GlobalState.rejectServiceRuntime(messenger))
            "verifyRuntimeIdentity" -> {
                val originChannel = channel
                confirmRuntimeIdentity(result, call.argument<Any>("epoch")) {
                    activeChannels.contains(originChannel)
                }
            }
            "startVpn" -> handleStartVpn(call, result)
            "stopVpn" -> {
                VpnPlugin.handleStop(force = true) { VpnPlugin.completeStopResult(result, it) }
            }
            "smartStop" -> {
                VpnPlugin.handleSmartStop { completed, generation ->
                    VpnPlugin.completeStopResult(result, completed) { VpnPlugin.smartStopReceiptCurrent(generation) }
                }
            }
            "smartResume" -> {
                val data = call.argument<String>("data")
                val options = gson.fromJson(data, VpnOptions::class.java)
                VpnPlugin.handleSmartResume(options) { receipt ->
                    VpnPlugin.completeSmartResumeResult(result, receipt)
                }
            }
            "setSmartStopped" -> {
                GlobalState.isSmartStopped = call.argument<Boolean>("value") ?: false
                result.success(true)
            }
            "isSmartStopped" -> result.success(GlobalState.isSmartStopped)
            "getLocalIpAddresses" -> result.success(VpnPlugin.getLocalIpAddresses())
            "setQuickResponse" -> {
                VpnPlugin.setQuickResponse(call.argument<Boolean>("enabled") ?: false)
                result.success(true)
            }
            "init" -> {
                GlobalState.getCurrentAppPlugin()?.requestNotificationsPermission()
                GlobalState.initServiceEngine()
                result.success(true)
            }
            "isServiceEngineRunning" -> result.success(GlobalState.isServiceEngineRunning())
            "status" -> result.success(GlobalState.currentRunState == RunState.START)
            "reconnectIpc" -> {
                GlobalState.reconnectIpc()
                result.success(true)
            }
            "destroy" -> {
                GlobalState.destroyServiceEngine()
                result.success(true)
            }
            "updateNotificationSpeed" -> {
                VpnPlugin.handleUpdateNotificationSpeed(
                    call.argument<String>("profileName") ?: "",
                    call.argument<String>("speedInfo") ?: ""
                )
                result.success(true)
            }
            "restoreNotification" -> {
                val context = com.appshub.bettbox.BettboxApplication.getAppContext()
                if (context != null) {
                    com.appshub.bettbox.GlobalState.isSpeedNotificationEnabled = false
                    android.service.quicksettings.TileService.requestListeningState(
                        context,
                        android.content.ComponentName(context, com.appshub.bettbox.services.BettboxTileService::class.java)
                    )

                    val intent = android.content.Intent(
                        context, 
                        com.appshub.bettbox.services.BettboxVpnService::class.java
                    ).apply {
                        action = "RESTORE_NOTIFICATION"
                    }
                    runCatching { context.startService(intent) }
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleStartVpn(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<String>("data")
        if (data.isNullOrBlank() || data == "null") {
            result.error("INVALID_ARGUMENT", "options data is null", null)
            return
        }
        runCatching { gson.fromJson(data, VpnOptions::class.java) }
            .onSuccess { options ->
                result.success(VpnPlugin.handleStart(options))
            }
            .onFailure { result.error("PARSE_ERROR", it.message, null) }
    }
}
