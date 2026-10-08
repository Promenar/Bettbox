package com.appshub.bettbox.plugins

object VpnPermissionRequestsFixture {
    @JvmStatic fun main(args: Array<String>) {
        var code = 4000
        val requests = VpnPermissionRequests { ++code }
        val completions = mutableListOf<Boolean>()
        var launched = 0
        requests.request({ true }, { launched = it; true }, completions::add)
        check(requests.result(launched, false))
        check(completions == listOf(false)) { "拒绝授权必须结束请求" }
        check(!requests.result(launched, true))
        requests.request({ true }, { false }, completions::add)
        check(completions == listOf(false, false))
        requests.request({ error("公开权限检查失败") }, { error("不得启动") }, completions::add)
        check(completions.last() == false)
        requests.request({ false }, { error("已授权无需启动") }, completions::add)
        check(completions.last())
        val shared = mutableListOf<Boolean>()
        var launches = 0
        requests.request({ true }, { launched = it; launches++; true }, shared::add)
        requests.request({ error("共享已打开的弹窗") }, { error("不得重复弹窗") }, shared::add)
        check(launches == 1)
        check(!requests.result(42, true))
        check(shared.isEmpty())
        check(requests.result(launched, true))
        check(shared == listOf(true, true))
        val late = launched
        requests.request({ true }, { launched = it; true }, shared::add)
        requests.cancel()
        check(shared.last() == false)
        requests.request({ true }, { launched = it; true }, shared::add)
        check(!requests.result(late, true))
        check(requests.result(launched, false))
        requests.request({ true }, { throw IllegalStateException() }, shared::add)
        check(shared.last() == false)
        val exhausted = VpnPermissionRequests { null }
        exhausted.request({ true }, { error("耗尽不得启动") }, shared::add)
        check(shared.last() == false)
        var reentered = 0
        requests.request({ true }, { launched = it; true }) {
            requests.request({ false }, { false }) { granted -> if (granted) reentered++ }
        }
        check(requests.result(launched, true))
        check(reentered == 1)
        println("权限拒绝、缺少Activity、检查异常、共享弹窗、旧结果、取消及重入验证通过")
    }
}
