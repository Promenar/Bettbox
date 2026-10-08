package com.appshub.bettbox.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger

// 仅使用公开数字和关闭计数，不创建 Android 设备或实际 FD。
fun main() {
    var closes = 0
    val unclaimed = TunFDLease(7) { check(it == 7); closes++ }
    check(unclaimed.closeUnclaimed() && unclaimed.closeUnclaimed())
    check(unclaimed.claim() == -1 && unclaimed.peek() == -1 && closes == 1)

    val claimed = TunFDLease(8) { error("已领取 FD 不得由 Kotlin 关闭") }
    check(claimed.peek() == 8 && claimed.claim() == 8 && claimed.claim() == -1)
    check(claimed.closeUnclaimed())

    var attempts = 0
    val failed = TunFDLease(9) { attempts++; error("公开关闭失败") }
    check(!failed.closeUnclaimed() && !failed.closeUnclaimed())
    check(attempts == 1 && failed.claim() == -1)

    val zero = TunFDLease(0) { error("非VPN零FD不得关闭标准输入") }
    check(zero.claim() == 0 && zero.closeUnclaimed())

    val zeroUnclaimed = TunFDLease(0) { error("非VPN零FD不得关闭标准输入") }
    check(zeroUnclaimed.closeUnclaimed())

    val count = AtomicInteger()
    val racing = TunFDLease(10) { count.incrementAndGet() }
    val start = CountDownLatch(1)
    val claimedFD = AtomicInteger(-1)
    val claimer = Thread { start.await(); claimedFD.set(racing.claim()) }
    val closer = Thread { start.await(); racing.closeUnclaimed() }
    claimer.start(); closer.start(); start.countDown()
    claimer.join(); closer.join()
    check((claimedFD.get() == 10 && count.get() == 0) || (claimedFD.get() == -1 && count.get() == 1))
    println("{\"lease_cases_passed\":6,\"actual_FD_used\":false}")
}
