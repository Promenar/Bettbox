package com.appshub.bettbox.core

import java.util.concurrent.atomic.AtomicBoolean

fun main() {
    var closed=0
    val clean=OwnedTunInvocation.start(TunFDLease(7){closed++},AtomicBoolean(false)){"public"}
    check(closed==1 && clean.input.disposition==TunFDDisposition.RELEASED && !clean.bridgeBlocked)
    val claimedLease=TunFDLease(8){error("不应重复关闭已移交FD")}
    val claimed=OwnedTunInvocation.start(claimedLease,AtomicBoolean(false)){check(claimedLease.claim()==8);"public"}
    check(claimed.input.disposition==TunFDDisposition.CLAIMED && !claimed.bridgeBlocked)
    val sticky=AtomicBoolean(false)
    val missing=OwnedTunInvocation.start(TunFDLease(9){closed++},sticky){null}
    check(missing.receipt==null && missing.bridgeBlocked && missing.input.disposition==TunFDDisposition.RELEASED)
    var invoked=false
    val later=OwnedTunInvocation.start(TunFDLease(10){closed++},sticky){invoked=true;"public"}
    check(!invoked && later.bridgeBlocked && later.input.disposition==TunFDDisposition.RELEASED)
    val failed=OwnedTunInvocation.start(TunFDLease(11){error("公开关闭失败")},AtomicBoolean(false)){"public"}
    check(failed.bridgeBlocked && failed.input.disposition==TunFDDisposition.UNKNOWN)
    val throwLease=TunFDLease(12){error("已领取FD不应本地关闭")}
    val thrown=OwnedTunInvocation.start(throwLease,AtomicBoolean(false)){throwLease.claim();error("公开桥失败")}
    check(thrown.bridgeBlocked && thrown.input.disposition==TunFDDisposition.CLAIMED)
    println("{\"invocation_cases\":6,\"failed\":0,\"actual_FD\":false}")
}
