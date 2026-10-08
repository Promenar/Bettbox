package com.appshub.bettbox.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

// 仅使用公开数字和关闭计数，不创建 Android 设备或实际 FD。
fun main() {
    var closes = 0
    val unclaimed = TunFDLease(7) { check(it == 7); closes++ }
    val beforeRelease = unclaimed.snapshot()
    check(beforeRelease.disposition == TunFDDisposition.UNCLAIMED)
    check(unclaimed.closeUnclaimed() && unclaimed.closeUnclaimed())
    check(unclaimed.claim() == -1 && unclaimed.peek() == -1 && closes == 1)
    check(unclaimed.snapshot().disposition == TunFDDisposition.RELEASED) { "未领取输入关闭后必须为RELEASED" }
    check(beforeRelease.disposition == TunFDDisposition.UNCLAIMED)

    val claimed = TunFDLease(8) { error("已领取 FD 不得由 Kotlin 关闭") }
    val beforeClaim = claimed.snapshot()
    check(claimed.peek() == 8 && claimed.claim() == 8 && claimed.claim() == -1)
    check(claimed.closeUnclaimed())
    check(claimed.snapshot().disposition == TunFDDisposition.CLAIMED) { "领取后不得把本地关闭成功解释为Go已释放" }
    check(beforeClaim.disposition == TunFDDisposition.UNCLAIMED)

    var attempts = 0
    val failed = TunFDLease(9) { attempts++; error("公开关闭失败") }
    check(failed.snapshot().disposition == TunFDDisposition.UNCLAIMED)
    check(!failed.closeUnclaimed() && !failed.closeUnclaimed())
    check(attempts == 1 && failed.claim() == -1)
    check(failed.snapshot().disposition == TunFDDisposition.UNKNOWN) { "关闭失败必须保留UNKNOWN" }

    val zero = TunFDLease(0) { error("非VPN零FD不得关闭标准输入") }
    check(zero.snapshot().disposition == TunFDDisposition.UNCLAIMED)
    check(zero.claim() == 0 && zero.closeUnclaimed())
    check(zero.snapshot().disposition == TunFDDisposition.CLAIMED) { "零FD占位领取后必须为CLAIMED" }

    val zeroUnclaimed = TunFDLease(0) { error("非VPN零FD不得关闭标准输入") }
    check(zeroUnclaimed.snapshot().disposition == TunFDDisposition.UNCLAIMED)
    check(zeroUnclaimed.closeUnclaimed())
    check(zeroUnclaimed.snapshot().disposition == TunFDDisposition.RELEASED) { "零FD占位未领取收尾后必须为RELEASED" }

    val count = AtomicInteger()
    val racing = TunFDLease(10) { count.incrementAndGet() }
    check(racing.snapshot().disposition == TunFDDisposition.UNCLAIMED)
    val start = CountDownLatch(1)
    val claimedFD = AtomicInteger(-1)
    val claimer = Thread { start.await(); claimedFD.set(racing.claim()) }
    val closer = Thread { start.await(); racing.closeUnclaimed() }
    claimer.start(); closer.start(); start.countDown()
    claimer.join(); closer.join()
    check((claimedFD.get() == 10 && count.get() == 0) || (claimedFD.get() == -1 && count.get() == 1))
    val expected = if (claimedFD.get() == 10) TunFDDisposition.CLAIMED else TunFDDisposition.RELEASED
    check(racing.snapshot().disposition == expected) { "并发领取与关闭后的快照不符" }
    for (fail in listOf(false, true)) {
        lateinit var reentrant: TunFDLease
        var during: TunFDSnapshot? = null
        var recursiveConfirmed = true
        var closeCalls = 0
        reentrant = TunFDLease(11) {
            closeCalls++
            during = reentrant.snapshot()
            recursiveConfirmed = reentrant.closeUnclaimed()
            if (fail) error("公开重入关闭失败")
        }
        check(reentrant.closeUnclaimed() == !fail)
        check(during?.disposition == TunFDDisposition.UNCLAIMED) { "关闭回调未完成不得提前报告RELEASED" }
        check(!recursiveConfirmed) { "重入关闭不得伪造收尾确认" }
        val expectedFinal = if (fail) TunFDDisposition.UNKNOWN else TunFDDisposition.RELEASED
        check(reentrant.snapshot().disposition == expectedFinal)
        check(reentrant.closeUnclaimed() == !fail && closeCalls == 1)
    }
    println("{\"lease_cases_passed\":6,\"actual_FD_used\":false}")
}
