package com.appshub.bettbox

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.StandardCopyOption

internal interface PackageRestartStore {
    fun readEligible(): Boolean
    fun writeEligible(value: Boolean): Boolean
    fun deleteEligibility(): Boolean
    fun stopBarrierClear(): Boolean
}

// 只承载非秘密恢复资格；调用方用 runLock 串行化资格和生命周期提交。
internal class PackageRestartEligibility(storeProvider: () -> PackageRestartStore) {
    constructor(store: PackageRestartStore) : this({ store })
    private val store by lazy(storeProvider)
    private var blocked = false

    fun mayRestore(): Boolean {
        if (blocked) return false
        return runCatching { store.readEligible() && store.stopBarrierClear() }.getOrDefault(false)
    }

    fun grantConfirmedRun(): Boolean {
        val confirmed = runCatching { store.writeEligible(true) }.getOrDefault(false)
        blocked = !confirmed
        return confirmed
    }

    fun revoke(): Boolean {
        blocked = true
        val confirmed = runCatching { store.writeEligible(false) }.getOrDefault(false) ||
            runCatching { store.deleteEligibility() }.getOrDefault(false)
        blocked = !confirmed
        return confirmed
    }
}

internal class FilePackageRestartStore(
    private val file: File,
    private val stopClear: () -> Boolean
) : PackageRestartStore {
    override fun readEligible(): Boolean = try {
        Files.readAllBytes(file.toPath()).contentEquals("v1:eligible\n".toByteArray(Charsets.UTF_8))
    } catch (_: NoSuchFileException) {
        false
    }

    override fun writeEligible(value: Boolean): Boolean {
        val directory = checkNotNull(file.parentFile).toPath()
        Files.createDirectories(directory)
        val temporary = Files.createTempFile(directory, "restart-", ".tmp")
        try {
            FileOutputStream(temporary.toFile()).use { output ->
                output.write((if (value) "v1:eligible\n" else "v1:stopped\n").toByteArray(Charsets.UTF_8))
                output.flush()
                output.fd.sync()
            }
            // 不支持同目录原子替换时传播失败，不降级为普通覆盖。
            Files.move(temporary, file.toPath(), StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING)
            return true
        } finally {
            Files.deleteIfExists(temporary)
        }
    }

    override fun deleteEligibility(): Boolean {
        Files.deleteIfExists(file.toPath())
        return true
    }

    override fun stopBarrierClear(): Boolean = stopClear()
}
