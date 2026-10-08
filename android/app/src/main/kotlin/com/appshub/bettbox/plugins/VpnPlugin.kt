package com.appshub.bettbox.plugins

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.service.quicksettings.TileService
import androidx.core.content.getSystemService
import com.appshub.bettbox.BettboxApplication
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.RunState
import com.appshub.bettbox.core.Core
import com.appshub.bettbox.extensions.awaitResult
import com.appshub.bettbox.extensions.asSocketAddressText
import com.appshub.bettbox.extensions.resolveDns
import com.appshub.bettbox.models.StartForegroundParams
import com.appshub.bettbox.models.VpnOptions
import com.appshub.bettbox.modules.SuspendModule
import com.appshub.bettbox.services.BaseServiceInterface
import com.appshub.bettbox.services.BettboxService
import com.appshub.bettbox.services.BettboxTileService
import com.appshub.bettbox.services.BettboxVpnService
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import java.util.Collections
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.withLock

data object VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    @Volatile
    private var bettBoxService: BaseServiceInterface? = null
    @Volatile
    private var options: VpnOptions? = null

    @Volatile
    private var isBind = false
    private val isBinding = AtomicBoolean(false)
    private val nativeGate = VpnWorkGate()
    private val lifecycleScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val lifecycle = VpnLifecycle<BaseServiceInterface>()
    private var startRequested = false
    private var localCleanupFailed = false
    private val intents = VpnIntentController()
    private var serviceConnection: ServiceConnection? = null
    private var bindingTicket: VpnIntentController.Binding? = null
    private var coldRecoveryChecked = false

    private var job = SupervisorJob()
    private var scope = CoroutineScope(Dispatchers.Default + job as kotlin.coroutines.CoroutineContext)
    private var lastStartForegroundParams: StartForegroundParams? = null
    private val uidPageNameMap = ConcurrentHashMap<Int, String>()
    private var suspendModule: SuspendModule? = null

    @Volatile
    private var quickResponseEnabled = false
    private var quickResponseJob: Job? = null
    private var lastNetworkType: Int? = null
    private var lastDns = ""

    val networks: MutableSet<Network> = Collections.newSetFromMap(ConcurrentHashMap())

    private val connectivity by lazy {
        BettboxApplication.getAppContext().getSystemService<ConnectivityManager>()
    }

    private var bindTimeoutJob: Job? = null
    private val attachedMessengers = Collections.newSetFromMap(ConcurrentHashMap<BinaryMessenger, Boolean>())
    private val channelMap = ConcurrentHashMap<BinaryMessenger, MethodChannel>()
    private val activeChannels = CopyOnWriteArrayList<MethodChannel>()
    private val networkCallbackRegistered = AtomicBoolean(false)

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val isFirstAttach = attachedMessengers.isEmpty()
        attachedMessengers.add(flutterPluginBinding.binaryMessenger)

        if (job.isCancelled) {
            job = SupervisorJob()
            scope = CoroutineScope(Dispatchers.Default + job as kotlin.coroutines.CoroutineContext)
        }

        val channel = MethodChannel(flutterPluginBinding.binaryMessenger, "vpn")
        channel.setMethodCallHandler(this)
        channelMap[flutterPluginBinding.binaryMessenger] = channel
        activeChannels.add(channel)

        if (isFirstAttach) {
            scope.launch { registerNetworkCallback() }
        }

        scope.launch {
            var dns = when {
                lastDns.isNotBlank() -> lastDns
                else -> getCurrentDns()
            }
            if (dns.isBlank()) {
                delay(1000)
                dns = getCurrentDns()
                if (dns.isNotBlank()) lastDns = dns
            }
            withContext(Dispatchers.Main) {
                runCatching {
                    channel.invokeMethod("dnsChanged", dns)
                }
            }
        }

        if (GlobalState.currentRunState == RunState.START && bettBoxService == null) handleStop(force = true)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        attachedMessengers.remove(flutterPluginBinding.binaryMessenger)
        channelMap.remove(flutterPluginBinding.binaryMessenger)?.let { channel ->
            channel.setMethodCallHandler(null)
            activeChannels.remove(channel)
        }

        if (attachedMessengers.isEmpty()) {
            unRegisterNetworkCallback()
            job.cancel()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                try {
                    val data = call.argument<String>("data")
                    if (data == null) {
                        result.error("INVALID_ARGUMENT", "data parameter is required", null)
                        return
                    }
                    val vpnOptions = Gson().fromJson(data, VpnOptions::class.java)
                    result.success(handleStart(vpnOptions))
                } catch (e: Exception) {
                    android.util.Log.e("VpnPlugin", "VPN 启动参数处理失败")
                    result.error("PARSE_ERROR", "VPN 启动参数处理失败", null)
                }
            }

            "stop" -> {
                handleStop()
                result.success(true)
            }

            "getLocalIpAddresses" -> {
                result.success(getLocalIpAddresses())
            }

            "setSmartStopped" -> {
                val value = call.argument<Boolean>("value") ?: false
                GlobalState.isSmartStopped = value
                result.success(true)
            }

            "isSmartStopped" -> {
                result.success(GlobalState.isSmartStopped)
            }

            "smartStop" -> {
                handleSmartStop()
                result.success(true)
            }

            "smartResume" -> {
                val data = call.argument<String>("data")
                result.success(handleSmartResume(Gson().fromJson(data, VpnOptions::class.java)))
            }
            
            "setQuickResponse" -> {
                quickResponseEnabled = call.argument<Boolean>("enabled") ?: false
                result.success(true)
            }

            "updateNotificationSpeed" -> {
                handleUpdateNotificationSpeed(
                    call.argument<String>("profileName") ?: "",
                    call.argument<String>("speedInfo") ?: ""
                )
                result.success(true)
            }

            "status" -> {
                result.success(GlobalState.currentRunState == RunState.START)
            }

            else -> {
                result.notImplemented()
            }
        }
    }
    
    fun setQuickResponse(enabled: Boolean) {
        quickResponseEnabled = enabled
    }

    fun getLocalIpAddresses(): List<String> = runCatching {
        networks.flatMap { network ->
            connectivity?.getLinkProperties(network)
                ?.linkAddresses
                ?.mapNotNull { it.address }
                ?.filter { !it.isLoopbackAddress && it.hostAddress?.contains(":") == false }
                ?.mapNotNull { it.hostAddress }
                ?: emptyList()
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "本地地址读取失败")
        emptyList()
    }

    fun handleStart(options: VpnOptions): Boolean {
        onUpdateNetwork()
        var request: VpnIntentController.Intent? = null
        var recover = false
        val accepted = GlobalState.runLock.withLock {
            recover = !coldRecoveryChecked && !GlobalState.isStopping && GlobalState.isCurrentlyStopping()
            if (startRequested || (GlobalState.isCurrentlyStopping() && !recover) || localCleanupFailed ||
                lifecycle.phase == VpnLifecycle.Phase.BLOCKED ||
                lifecycle.phase == VpnLifecycle.Phase.STARTING) return@withLock false
            if (lifecycle.phase == VpnLifecycle.Phase.RUNNING) {
                scope.launch { startForeground() }
                return@withLock false
            }
            if (options.enable != this.options?.enable) this.bettBoxService = null
            this.options = options
            request = intents.request()
            startRequested = true
            GlobalState.isSmartStopped = false
            GlobalState.updateRunState(RunState.PENDING)
            true
        }
        if (!accepted) return false
        val intent = request ?: return false
        if (recover) {
            lifecycleScope.launch {
                nativeGate.recover(current = {
                    GlobalState.runLock.withLock { intents.current(intent) && startRequested }
                }, stop = {
                    if (!isMainProcess()) {
                        android.util.Log.e("VpnPlugin", "停止锁恢复仅允许主进程执行")
                        false
                    } else Core.stopTun()
                }, commit = { recovered ->
                    val resume = GlobalState.runLock.withLock {
                        coldRecoveryChecked = true
                        when (intents.recovered(intent, recovered)) {
                            VpnIntentController.Recovery.CANCELLED -> return@withLock false
                            VpnIntentController.Recovery.FAILED -> {
                                markBlocked()
                                return@withLock false
                            }
                            VpnIntentController.Recovery.READY -> Unit
                        }
                        GlobalState.updateIsStopping(false)
                        true
                    }
                    if (resume) dispatchStart(intent, options)
                })
            }
        } else {
            GlobalState.runLock.withLock { coldRecoveryChecked = true }
            dispatchStart(intent, options)
        }
        return true
    }

    private fun isMainProcess(): Boolean {
        val context = BettboxApplication.getAppContext()
        val processName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            android.app.Application.getProcessName()
        } else {
            context.getSystemService<android.app.ActivityManager>()?.runningAppProcesses
                ?.firstOrNull { it.pid == android.os.Process.myPid() }?.processName
        }
        return processName == context.packageName
    }

    private fun dispatchStart(intent: VpnIntentController.Intent, options: VpnOptions) {
        if (!GlobalState.runLock.withLock { intents.current(intent) && startRequested }) return
        when (options.enable) {
            true -> handleStartVpn(intent)
            false -> handleStartService(intent)
        }
    }

    private fun handleStartVpn(intent: VpnIntentController.Intent) {
        GlobalState.getCurrentAppPlugin()?.requestVpnPermission {
            handleStartService(intent)
        }
    }

    fun requestGc() {
        invokeDart("gc")
    }

    fun onUpdateNetwork() {
        val dns = getCurrentDns()
        if (dns == lastDns) return
        lastDns = dns
        invokeDart("dnsChanged", dns)
    }

    fun notifyScreenStateChanged(isOn: Boolean) {
        invokeDart("screenStateChanged", isOn)
    }

    private fun getCurrentDns(): String {
        val dnsSet = when {
            networkDnsMap.isNotEmpty() -> networkDnsMap.values.flatMap { it }
            else -> {
                val cm = connectivity
                val activeNetwork = cm?.activeNetwork
                activeNetwork?.let { cm.resolveDns(it) } ?: emptyList()
            }
        }.toSet()
        return when {
            dnsSet.isNotEmpty() -> dnsSet.joinToString(",")
            else -> getAllNetworksDns()
        }
    }

    private fun getAllNetworksDns(): String {
        return runCatching {
            connectivity?.allNetworks?.flatMap { network ->
                connectivity?.resolveDns(network) ?: emptyList()
            }?.filter { it.isNotBlank() }?.toSet()?.joinToString(",") ?: ""
        }.getOrElse { "" }
    }

    private val networkDnsMap = ConcurrentHashMap<Network, List<String>>()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            networks.add(network)
            handleNetworkChange()
        }

        override fun onLost(network: Network) {
            networks.remove(network)
            networkDnsMap.remove(network)
            onUpdateNetwork()
            handleNetworkChange()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val dnsList = linkProperties.dnsServers.map { it.asSocketAddressText(53) }
            networkDnsMap[network] = dnsList
            onUpdateNetwork()
        }
    }

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private fun registerNetworkCallback() {
        if (!networkCallbackRegistered.compareAndSet(false, true)) return
        runCatching {
            networks.clear()
            connectivity?.registerNetworkCallback(request, callback)
        }.onFailure {
            networkCallbackRegistered.set(false)
            android.util.Log.e("VpnPlugin", "网络回调注册失败")
        }
    }

    private fun unRegisterNetworkCallback() {
        if (!networkCallbackRegistered.compareAndSet(true, false)) return
        runCatching {
            connectivity?.unregisterNetworkCallback(callback)
        }.onFailure {
            android.util.Log.e("VpnPlugin", "网络回调注销失败")
        }.also {
            networks.clear()
            networkDnsMap.clear()
            onUpdateNetwork()
        }
    }
    
    private fun handleNetworkChange() {
        val currentNetworkType = getCurrentNetworkType()
        if (lastNetworkType == null) {
            lastNetworkType = currentNetworkType
            return
        }

        if (currentNetworkType != lastNetworkType) {
            lastNetworkType = currentNetworkType

            ServicePlugin.notifyNetworkChanged()
            invokeDart("networkChanged")

            if (!quickResponseEnabled) return

            quickResponseJob?.cancel()
            quickResponseJob = scope.launch {
                delay(150)
                if (GlobalState.currentRunState == RunState.START) {
                    android.util.Log.d("VpnPlugin", "Quick Response: Network changed, notifying Dart")
                    ServicePlugin.notifyQuickResponse()
                }
            }
        }
    }

    private fun invokeDart(method: String, arguments: Any? = null) {
        if (activeChannels.isEmpty()) return
        scope.launch {
            withContext(Dispatchers.Main) {
                activeChannels.forEach { channel ->
                    runCatching { channel.invokeMethod(method, arguments) }
                        .onFailure {
                            android.util.Log.w("VpnPlugin", "Dart 回调失败")
                        }
                }
            }
        }
    }
    
    private fun getCurrentNetworkType(): Int {
        val activeNetwork = connectivity?.activeNetwork ?: return -1
        val caps = connectivity?.getNetworkCapabilities(activeNetwork) ?: return -1
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 1
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 3
            else -> 0
        }
    }

    private suspend fun startForeground() {
        val service = GlobalState.runLock.withLock { lifecycle.ticket?.service } ?: return
        val generation = foregroundGeneration(service) ?: return
        try {
            service.startForeground(generation)
        } catch (e: Exception) {
            android.util.Log.e("VpnPlugin", "前台通知发布失败")
        }
    }

    fun foregroundGeneration(service: BaseServiceInterface): Long? = GlobalState.runLock.withLock {
        if (lifecycle.canPublish(service)) lifecycle.ticket?.generation else null
    }

    fun publishForeground(service: BaseServiceInterface, generation: Long, publish: () -> Unit): Boolean =
        GlobalState.runLock.withLock {
            lifecycle.publish(service, generation, publish)
        }

    fun updateNotificationIcon() {
        val service = GlobalState.runLock.withLock { lifecycle.ticket?.service } ?: return
        val generation = foregroundGeneration(service) ?: return
        scope.launch {
            runCatching {
                val context = BettboxApplication.getAppContext()
                val notificationManager = context.getSystemService(android.app.NotificationManager::class.java)
                if (publishForeground(service, generation) {
                    notificationManager?.cancel(GlobalState.NOTIFICATION_ID)
                    (service as? BettboxService)?.resetNotificationBuilder()
                    (service as? BettboxVpnService)?.resetNotificationBuilder()
                }) service.startForeground(generation)
            }.onFailure {
                android.util.Log.e("VpnPlugin", "通知图标更新失败")
            }
        }
    }

    fun handleUpdateNotificationSpeed(profileName: String, speedInfo: String) {
        if (profileName != GlobalState.currentProfileName ||
            !GlobalState.isSpeedNotificationEnabled
        ) {
            GlobalState.currentProfileName = profileName
            GlobalState.isSpeedNotificationEnabled = true
            val context = BettboxApplication.getAppContext()
            TileService.requestListeningState(
                context,
                ComponentName(context, BettboxTileService::class.java)
            )
        }
        updateNotificationSpeed(profileName, speedInfo)
    }

    fun updateNotificationSpeed(profileName: String, speedInfo: String) {
        val service = GlobalState.runLock.withLock { lifecycle.ticket?.service } as? BettboxVpnService ?: return
        val generation = foregroundGeneration(service) ?: return
        scope.launch {
            runCatching {
                service.updateNotificationSpeed(profileName, speedInfo, generation)
            }.onFailure {
                android.util.Log.e("VpnPlugin", "通知速度更新失败")
            }
        }
    }

    fun getStatus(): Boolean {
        return GlobalState.runLock.withLock {
            GlobalState.currentRunState == RunState.START && bettBoxService != null
        }
    }

    private fun handleStartService(intent: VpnIntentController.Intent) {
        if (!GlobalState.runLock.withLock { intents.current(intent) && startRequested && !GlobalState.isCurrentlyStopping() }) {
            android.util.Log.w("VpnPlugin", "VPN is in stopping state, ignore start request")
            return
        }
        if (bettBoxService == null) {
            bindService(intent)
            return
        }
        
        scope.launch {
            try {
                val prepareIntent = try {
                    android.net.VpnService.prepare(BettboxApplication.getAppContext())
                } catch (e: Exception) {
                    null
                }

                if (prepareIntent != null) {
                    android.util.Log.w("VpnPlugin", "VPN permission required before start")
                    withContext(Dispatchers.Main) {
                        GlobalState.getCurrentAppPlugin()?.requestVpnPermission {
                            handleStartService(intent)
                        }
                    }
                    return@launch
                }

                val currentOptions = options
                val ticket = GlobalState.runLock.withLock {
                    if (!intents.current(intent) || !startRequested || GlobalState.isCurrentlyStopping() || currentOptions == null) return@withLock null
                    val service = bettBoxService ?: return@withLock null
                    val captured = lifecycle.begin(service) ?: return@withLock null
                    startRequested = false
                    GlobalState.updateRunState(RunState.PENDING)
                    lastStartForegroundParams = null
                    captured
                }
                if (ticket == null || currentOptions == null) return@launch
                performStartCore(ticket, currentOptions, retry = true, notifyOnFailure = true)
            } catch (e: Exception) {
                android.util.Log.e("VpnPlugin", "启动流程失败")
                stopIntent(intent)
            }
        }
    }

    private suspend fun performStartCore(
        ticket: VpnLifecycle.Ticket<BaseServiceInterface>,
        currentOptions: VpnOptions,
        retry: Boolean,
        notifyOnFailure: Boolean
    ) {
        var detachedFd = -1
        try {
            nativeGate.start(prepare = prepare@{
                if (!isCurrent(ticket)) return@prepare
                detachedFd = runCatching { ticket.service.start(currentOptions) }.getOrElse { -1 }
                if (!isCurrent(ticket)) return@prepare
                if (currentOptions.enable && detachedFd <= 0 && retry) {
                    delay(300)
                    if (!isCurrent(ticket)) return@prepare
                    detachedFd = runCatching { ticket.service.start(currentOptions) }.getOrElse { -1 }
                    if (!isCurrent(ticket)) return@prepare
                }
                if (detachedFd < 0 || (currentOptions.enable && detachedFd == 0)) {
                    failStart(ticket, cleanupSucceeded = true, notify = notifyOnFailure)
                    return@prepare
                }
            }, consume = {
                if (!isCurrent(ticket) || detachedFd < 0) return@start
                val nativeFd = detachedFd
                Core.suspended(false)
                if (!isCurrent(ticket)) return@start
                // Core 从此负责未领取输入的关闭；Go 领取后负责其所有权。
                detachedFd = -1
                val started = Core.startTun(nativeFd, { fd ->
                    runCatching { isCurrent(ticket) && (ticket.service as? BettboxVpnService)?.protect(fd) == true }
                        .getOrElse { false }
                }, this@VpnPlugin::resolverProcess)
                if (!started || !isCurrent(ticket)) {
                    val cleaned = Core.stopTun()
                    if (isCurrent(ticket)) failStart(ticket, cleaned, notifyOnFailure)
                    else if (!cleaned) markBlocked()
                    return@start
                }
                val committed = GlobalState.runLock.withLock {
                    if (!lifecycle.started(ticket)) return@withLock false
                    GlobalState.updateRunState(RunState.START)
                    true
                }
                if (committed && isCurrent(ticket)) {
                    if (currentOptions.dozeSuspend) {
                        suspendModule?.uninstall()
                        suspendModule = SuspendModule(BettboxApplication.getAppContext())
                        suspendModule?.install()
                    }
                    ticket.service.startForeground(ticket.generation)
                }
            }, finish = {
                if (detachedFd > 0 && !closeDetachedFd(detachedFd)) markBlocked()
            })
            onUpdateNetwork()
        } catch (e: Exception) {
            android.util.Log.e("VpnPlugin", "VPN 启动失败")
            withContext(NonCancellable) {
                nativeGate.run {
                    if (isCurrent(ticket)) failStart(ticket, Core.stopTun(), notifyOnFailure)
                }
            }
        }
    }

    private fun isCurrent(ticket: VpnLifecycle.Ticket<BaseServiceInterface>) =
        GlobalState.runLock.withLock { lifecycle.current(ticket) }

    private fun closeDetachedFd(fd: Int): Boolean = runCatching {
        ParcelFileDescriptor.adoptFd(fd).close()
        true
    }.getOrElse {
        GlobalState.runLock.withLock { localCleanupFailed = true }
        android.util.Log.e("VpnPlugin", "未交接 TUN 输入关闭失败")
        false
    }

    private fun markBlocked() = GlobalState.runLock.withLock {
        lifecycle.block()
        intents.cancelIntent()
        startRequested = false
        GlobalState.updateIsStopping(true)
        GlobalState.updateRunState(RunState.PENDING)
    }

    private fun failStart(ticket: VpnLifecycle.Ticket<BaseServiceInterface>, cleanupSucceeded: Boolean, notify: Boolean) {
        GlobalState.runLock.withLock {
            if (!lifecycle.failed(ticket, cleanupSucceeded && !localCleanupFailed)) return
            GlobalState.updateIsStopping(!cleanupSucceeded || localCleanupFailed)
            GlobalState.updateRunState(if (cleanupSucceeded && !localCleanupFailed) RunState.STOP else RunState.PENDING)
            if (notify) ServicePlugin.notifyVpnStartFailed()
            if (cleanupSucceeded && !localCleanupFailed) handleStop(force = true)
        }
    }

    private fun resolverProcess(
        protocol: Int,
        source: InetSocketAddress,
        target: InetSocketAddress,
        uid: Int,
    ): String = runCatching {
        val nextUid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            connectivity?.getConnectionOwnerUid(protocol, source, target) ?: -1
        } else {
            uid
        }
        if (nextUid == -1) {
            return@runCatching ""
        }
        uidPageNameMap.getOrPut(nextUid) {
            BettboxApplication.getAppContext().packageManager?.getPackagesForUid(nextUid)
                ?.firstOrNull() ?: ""
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "进程解析失败")
        ""
    }

    fun handleStop(force: Boolean = false) {
        val serviceRef: BaseServiceInterface?
        val connectionRef: ServiceConnection?
        val shouldForceStop: Boolean
        val stopGeneration: Long
        GlobalState.runLock.withLock {
            if (!force && lifecycle.phase == VpnLifecycle.Phase.IDLE && !startRequested) return
            startRequested = false
            intents.cancel()
            connectionRef = serviceConnection
            serviceConnection = null
            bindingTicket = null
            isBinding.set(false)
            bindTimeoutJob?.cancel()
            bindTimeoutJob = null
            stopGeneration = lifecycle.invalidate()
            GlobalState.updateIsStopping(true)
            GlobalState.updateRunState(RunState.PENDING)
            serviceRef = bettBoxService
            shouldForceStop = force || bettBoxService == null
        }

        lifecycleScope.launch {
            withContext(NonCancellable) {
                nativeGate.run {
                    val current = GlobalState.runLock.withLock {
                        lifecycle.phase == VpnLifecycle.Phase.STOPPING &&
                            stopGeneration == currentGeneration()
                    }
                    if (!current) return@run
                    val stopped = Core.stopTun() && !localCleanupFailed
                    if (!stopped) {
                        GlobalState.runLock.withLock { lifecycle.stopped(stopGeneration, false, false) }
                        android.util.Log.e("VpnPlugin", "TUN 停止失败，保持启动阻断")
                        return@run
                    }
                    suspendModule?.uninstall()
                    suspendModule = null
                    serviceRef?.stop()
                    val context = BettboxApplication.getAppContext()
                    runCatching {
                        connectionRef?.let { context.unbindService(it) }
                    }.onFailure { android.util.Log.e("VpnPlugin", "服务解绑失败") }
                    if (shouldForceStop) {
                        context.stopService(Intent(context, BettboxVpnService::class.java))
                        context.stopService(Intent(context, BettboxService::class.java))
                    }
                    GlobalState.runLock.withLock {
                        if (lifecycle.stopped(stopGeneration, true, false)) {
                            isBind = false
                            isBinding.set(false)
                            bettBoxService = null
                            GlobalState.isSmartStopped = false
                            GlobalState.updateIsStopping(false)
                            GlobalState.updateRunState(RunState.STOP)
                            ServicePlugin.notifyRunStateChanged(RunState.STOP)
                        }
                    }
                }
                if (GlobalState.runLock.withLock { lifecycle.phase == VpnLifecycle.Phase.IDLE }) {
                    withContext(Dispatchers.Main) {
                        GlobalState.runLock.withLock {
                            if (!startRequested && lifecycle.phase == VpnLifecycle.Phase.IDLE && currentGeneration() == stopGeneration) {
                                GlobalState.handleTryDestroy()
                            }
                        }
                    }
                }
            }
        }
    }

    private fun currentGeneration(): Long = lifecycle.generation

    fun handleSmartStop() {
        val stopGeneration = GlobalState.runLock.withLock {
            if (lifecycle.phase == VpnLifecycle.Phase.IDLE && !startRequested) return
            startRequested = false
            intents.cancelIntent()
            GlobalState.updateIsStopping(true)
            GlobalState.updateRunState(RunState.PENDING)
            lifecycle.invalidate()
        }
        lifecycleScope.launch {
            withContext(NonCancellable) {
                nativeGate.run {
                    if (GlobalState.runLock.withLock { currentGeneration() != stopGeneration }) return@run
                    val stopped = Core.stopTun() && !localCleanupFailed
                    if (stopped) {
                        suspendModule?.uninstall()
                        suspendModule = null
                        Core.suspended(true)
                    }
                    GlobalState.runLock.withLock {
                        if (lifecycle.stopped(stopGeneration, stopped, suspended = true)) {
                            GlobalState.isSmartStopped = true
                            GlobalState.updateIsStopping(false)
                            GlobalState.updateRunState(RunState.STOP)
                        }
                    }
                    if (stopped) startForeground()
                    else android.util.Log.e("VpnPlugin", "智能停止失败，保持启动阻断")
                }
            }
        }
    }

    fun handleSmartResume(options: VpnOptions): Boolean {
        return handleStart(options)
    }

    private fun stopIntent(intent: VpnIntentController.Intent) {
        GlobalState.runLock.withLock {
            if (intents.current(intent)) handleStop(force = true)
        }
    }

    private fun bindService(intent: VpnIntentController.Intent) {
        if (!isBinding.compareAndSet(false, true)) return
        val ticket = GlobalState.runLock.withLock {
            intents.beginBinding(intent, options?.enable == true)
        }
        if (ticket == null) {
            isBinding.set(false)
            return
        }
        val connection = object : ServiceConnection {
            override fun onServiceConnected(className: ComponentName, binder: IBinder) {
                val service = when (binder) {
                    is BettboxVpnService.LocalBinder -> binder.getService()
                    is BettboxService.LocalBinder -> binder.getService()
                    else -> null
                }
                val accepted = GlobalState.runLock.withLock {
                    if (!intents.current(ticket) || !intents.current(intent) || serviceConnection !== this) return@withLock false
                    if (service == null) {
                        stopIntent(intent)
                        return@withLock false
                    }
                    bindTimeoutJob?.cancel()
                    bindTimeoutJob = null
                    isBind = true
                    isBinding.set(false)
                    bettBoxService = service
                    true
                }
                if (accepted) handleStartService(intent)
                else runCatching { BettboxApplication.getAppContext().unbindService(this) }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                GlobalState.runLock.withLock {
                    if (!intents.current(ticket) || serviceConnection !== this) return
                    handleStop(force = true)
                    ServicePlugin.notifyVpnStartFailed()
                }
            }
        }
        val previous = GlobalState.runLock.withLock {
            if (!intents.current(ticket) || !intents.current(intent)) return
            serviceConnection.also {
                serviceConnection = connection
                bindingTicket = ticket
                isBind = false
            }
        }
        previous?.let { runCatching { BettboxApplication.getAppContext().unbindService(it) } }
        bindTimeoutJob?.cancel()
        bindTimeoutJob = scope.launch {
            delay(10_000L)
            GlobalState.runLock.withLock {
                if (intents.current(ticket) && intents.current(intent) && isBinding.get()) {
                    android.util.Log.w("VpnPlugin", "服务绑定超时")
                    stopIntent(intent)
                }
            }
        }

        try {
            if (!GlobalState.runLock.withLock { intents.current(ticket) && intents.current(intent) }) return
            val intent = Intent(
                BettboxApplication.getAppContext(),
                if (ticket.vpnEnabled) BettboxVpnService::class.java else BettboxService::class.java
            )
            val res = BettboxApplication.getAppContext().bindService(intent, connection, Context.BIND_AUTO_CREATE)
            if (!res) {
                android.util.Log.e("VpnPlugin", "系统拒绝服务绑定")
                stopIntent(ticket.intent)
            } else if (!GlobalState.runLock.withLock { intents.registered(ticket) }) {
                runCatching { BettboxApplication.getAppContext().unbindService(connection) }
            }
        } catch (e: Exception) {
            android.util.Log.e("VpnPlugin", "服务绑定失败")
            stopIntent(ticket.intent)
        }
    }
}
