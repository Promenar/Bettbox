package com.appshub.bettbox

import java.io.File

private class RestartStoreFixture : PackageRestartStore {
    var eligible = false
    var clear = true
    var failRead = false
    var failBarrier = false
    var failWrite = false
    var failDelete = false
    override fun readEligible(): Boolean {
        check(!failRead) { "读取故障" }
        return eligible
    }
    override fun stopBarrierClear(): Boolean {
        check(!failBarrier) { "屏障读取故障" }
        return clear
    }
    override fun writeEligible(value: Boolean): Boolean {
        if (failWrite) return false
        eligible = value
        return true
    }
    override fun deleteEligibility(): Boolean {
        check(!failDelete) { "删除故障" }
        eligible = false
        return true
    }
}

object PackageRestartFixture {
    @JvmStatic fun main(args: Array<String>) {
        val unavailable = PackageRestartEligibility { error("私有目录获取故障") }
        check(!unavailable.mayRestore())
        check(!unavailable.grantConfirmedRun())
        check(!unavailable.revoke()) { "存储初始化失败应返回未确认，不能中断资源清理" }
        val disk = RestartStoreFixture()
        val gate = PackageRestartEligibility(disk)
        check(!gate.mayRestore()) { "没有已确认运行资格时，更新不得启动" }
        check(gate.grantConfirmedRun())
        check(PackageRestartEligibility(disk).mayRestore()) { "已确认运行应可跨实例恢复" }
        disk.clear = false
        check(!gate.mayRestore()) { "停止屏障未清除时不得恢复" }
        disk.clear = true
        disk.failRead = true
        check(!gate.mayRestore())
        disk.failRead = false
        disk.failBarrier = true
        check(!gate.mayRestore())
        disk.failBarrier = false
        check(gate.revoke())
        check(!PackageRestartEligibility(disk).mayRestore()) { "普通停止必须跨实例撤销" }
        check(gate.grantConfirmedRun())
        disk.failWrite = true
        check(gate.revoke()) { "写入失败但确认删除时可以确认撤销" }
        check(!PackageRestartEligibility(disk).mayRestore())
        disk.failWrite = false
        check(gate.grantConfirmedRun())
        disk.failWrite = true
        disk.failDelete = true
        check(!gate.revoke()) { "双重存储失败不得报告停止成功" }
        check(disk.eligible) { "故障应保留旧磁盘事实，不能伪造持久撤销" }
        check(!gate.mayRestore()) { "未确认撤销必须阻断当前进程恢复" }
        check(!gate.grantConfirmedRun())
        check(!gate.mayRestore())
        disk.failWrite = false
        disk.failDelete = false
        check(gate.revoke())
        check(!gate.mayRestore())

        // 使用真正的临时文件验证原子替换、严格内容与跨实例读取。
        val directory = File(args.single())
        check(directory.mkdirs() || directory.isDirectory)
        val file = File(directory, "eligibility")
        check(!file.exists()) { "夹具目录必须独占且为空" }
        val actual = FilePackageRestartStore(file) { true }
        val actualGate = PackageRestartEligibility(actual)
        check(!actualGate.mayRestore())
        File(directory, "restart-uncommitted.tmp").writeText("v1:eligible\n")
        check(!actualGate.mayRestore()) { "未提交临时文件不能授予资格" }
        check(actualGate.grantConfirmedRun())
        check(PackageRestartEligibility(FilePackageRestartStore(file) { true }).mayRestore())
        file.writeText("v1:eligible\nextra")
        check(!actualGate.mayRestore()) { "损坏标记不得授予资格" }
        check(actualGate.grantConfirmedRun())
        check(actualGate.revoke())
        check(!PackageRestartEligibility(actual).mayRestore())
        check(actual.deleteEligibility())
        check(actual.deleteEligibility())
        check(!actualGate.mayRestore())
        // 非空目录模拟不能原子覆盖且不能删除的存储目标。
        check(file.mkdir())
        File(file, "child").writeText("公开夹具")
        val inaccessibleGate = PackageRestartEligibility(actual)
        check(!inaccessibleGate.mayRestore())
        check(!inaccessibleGate.grantConfirmedRun())
        check(!inaccessibleGate.revoke())
        check(!inaccessibleGate.mayRestore())
        check(directory.listFiles()!!.none { it.name.startsWith("restart-") && it.name != "restart-uncommitted.tmp" })
        check(directory.deleteRecursively())
    }
}
