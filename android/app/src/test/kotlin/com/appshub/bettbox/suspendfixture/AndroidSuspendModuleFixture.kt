package com.appshub.bettbox.suspendfixture

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import com.appshub.bettbox.core.Core
import com.appshub.bettbox.modules.SuspendModule
import com.appshub.bettbox.plugins.VpnPlugin
import kotlin.system.exitProcess

object AndroidSuspendModuleFixture {
    private const val CASES = 8

    @JvmStatic
    fun main(args: Array<String>) {
        val cases = listOf(
            ::rejectedSuspendRetries,
            ::rejectedIdleResumeRetries,
            ::rejectedScreenResumeRetries,
            ::rejectedUninstallResumeRetries,
            ::successfulCycle,
            ::unregisterFailureRetainsResponsibility,
            ::interactiveInstallDoesNotSuspend,
            ::reinstallRetainsPendingResume,
        )
        var passed = 0
        check(cases.size == CASES)
        cases.forEach { test ->
            try {
                Core.reset()
                VpnPlugin.reset()
                Build.VERSION.SDK_INT = Build.VERSION_CODES.M
                test()
                passed += 1
            } catch (_: Throwable) {
                // 每个场景独立统计，失败时不输出异常原文。
            }
        }
        println("{\"passed\":$passed,\"cases\":$CASES}")
        if (passed != CASES) exitProcess(1)
    }

    private fun idleContext() = Context().apply {
        powerManager.isInteractive = false
        powerManager.isDeviceIdleMode = true
    }

    private fun expectCalls(vararg expected: Boolean) {
        check(Core.calls == expected.toList()) { "核心调用序列不匹配" }
    }

    private fun rejectedSuspendRetries() {
        val context = idleContext()
        val module = SuspendModule(context)
        Core.respond(false, true)
        module.install()
        expectCalls(true)
        context.dispatch(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        expectCalls(true, true)
        context.dispatch(Intent.ACTION_SCREEN_OFF)
        expectCalls(true, true)
        check(module.uninstall())
        expectCalls(true, true, false)
        check(!context.receiverRegistered)
    }

    private fun rejectedIdleResumeRetries() {
        val context = idleContext()
        val module = SuspendModule(context)
        module.install()
        Core.respond(false, true)
        context.powerManager.isDeviceIdleMode = false
        context.dispatch(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        expectCalls(true, false)
        check(VpnPlugin.networkUpdates == 0)
        context.dispatch(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        expectCalls(true, false, false)
        check(VpnPlugin.networkUpdates == 1)
        context.dispatch(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        expectCalls(true, false, false)
        check(VpnPlugin.networkUpdates == 1)
        check(module.uninstall())
        expectCalls(true, false, false)
    }

    private fun rejectedScreenResumeRetries() {
        val context = idleContext()
        val module = SuspendModule(context)
        module.install()
        Core.respond(false, true)
        context.powerManager.isInteractive = true
        context.dispatch(Intent.ACTION_SCREEN_ON)
        expectCalls(true, false)
        context.dispatch(Intent.ACTION_SCREEN_ON)
        expectCalls(true, false, false)
        context.dispatch(Intent.ACTION_SCREEN_ON)
        expectCalls(true, false, false)
        check(VpnPlugin.networkUpdates == 0)
        check(module.uninstall())
        expectCalls(true, false, false)
    }

    private fun rejectedUninstallResumeRetries() {
        val context = idleContext()
        val module = SuspendModule(context)
        module.install()
        Core.respond(false, true)
        check(!module.uninstall())
        check(!context.receiverRegistered)
        check(context.unregisterCalls == 1)
        expectCalls(true, false)
        check(module.uninstall())
        expectCalls(true, false, false)
        check(context.unregisterCalls == 1)
        check(module.uninstall())
        expectCalls(true, false, false)
        check(context.unregisterCalls == 1)
    }

    private fun successfulCycle() {
        val context = idleContext()
        val module = SuspendModule(context)
        module.install()
        module.install()
        check(context.registerCalls == 1)
        expectCalls(true)
        context.dispatch(Intent.ACTION_SCREEN_OFF)
        expectCalls(true)
        context.powerManager.isDeviceIdleMode = false
        context.dispatch(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        expectCalls(true, false)
        check(VpnPlugin.networkUpdates == 1)
        context.powerManager.isDeviceIdleMode = true
        context.dispatch(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        expectCalls(true, false, true)
        check(module.uninstall())
        expectCalls(true, false, true, false)
        check(context.unregisterCalls == 1)
        check(!context.receiverRegistered)
        check(module.uninstall())
        expectCalls(true, false, true, false)
    }

    private fun unregisterFailureRetainsResponsibility() {
        val context = idleContext()
        val module = SuspendModule(context)
        module.install()
        context.unregisterFailures = 1
        check(!module.uninstall())
        check(context.receiverRegistered)
        check(context.unregisterCalls == 1)
        expectCalls(true)
        check(module.uninstall())
        check(!context.receiverRegistered)
        check(context.unregisterCalls == 2)
        expectCalls(true, false)
        check(module.uninstall())
        check(context.unregisterCalls == 2)
        expectCalls(true, false)
    }

    private fun interactiveInstallDoesNotSuspend() {
        val context = Context()
        val module = SuspendModule(context)
        module.install()
        expectCalls()
        check(context.receiverRegistered)
        check(module.uninstall())
        expectCalls()
        check(context.unregisterCalls == 1)
        check(!context.receiverRegistered)
    }

    private fun reinstallRetainsPendingResume() {
        val context = idleContext()
        val module = SuspendModule(context)
        module.install()
        Core.respond(false, false, true)
        check(!module.uninstall())
        context.powerManager.isInteractive = true
        module.install()
        expectCalls(true, false, false)
        check(module.uninstall())
        expectCalls(true, false, false, false)
        check(!context.receiverRegistered)
    }
}
