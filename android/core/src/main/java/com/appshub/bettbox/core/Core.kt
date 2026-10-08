package com.appshub.bettbox.core

import android.util.Log
import android.os.ParcelFileDescriptor
import java.util.concurrent.atomic.AtomicBoolean
import java.net.InetSocketAddress
import androidx.annotation.Keep

@Keep
object Core {

    private external fun getOwnedConfigStatusNative(): String?
    private external fun commitOwnedConfigNative(epoch: Long, revision: Long, kind: Int, payload: String): String?

    // 原始回执仅交给统一owner的严格解析器，不据此自行发布VPN状态。
    fun ownedConfigStatusRaw(): String = getOwnedConfigStatusNative()
        ?: throw IllegalStateException("配置状态读取未确认")

    fun commitOwnedConfigRaw(epoch: Long, revision: Long, kind: Int, payload: String): String =
        commitOwnedConfigNative(epoch, revision, kind, payload)
            ?: throw IllegalStateException("配置提交结果未知")

    private external fun startNativeTun(lease: TunFDLease, cb: TunInterface?): Boolean
    private external fun suspend(suspended: Int)
    private external fun stopNativeTun(): Boolean
    private val inputCleanupFailed = AtomicBoolean(false)

    fun stopTun(): Boolean = runCatching {
        stopNativeTun() && !inputCleanupFailed.get()
    }.getOrElse {
        Log.e("Core", "TUN 停止未确认")
        false
    }

    init {
        System.loadLibrary("core")
    }

    private fun parseInetSocketAddress(address: String): InetSocketAddress {
        val lastColonIndex = address.lastIndexOf(':')
        if (lastColonIndex == -1) {
            return InetSocketAddress(address, 0)
        }

        val host = address.substring(0, lastColonIndex).removeSurrounding("[", "]")
        val port = address.substring(lastColonIndex + 1).toIntOrNull() ?: 0

        return InetSocketAddress(host, port)
    }

    fun startTun(
        fd: Int,
        protect: (Int) -> Boolean,
        resolverProcess: (protocol: Int, source: InetSocketAddress, target: InetSocketAddress, uid: Int) -> String
    ): Boolean {
        if (fd < 0) return false
        val lease = TunFDLease(fd) { owned -> ParcelFileDescriptor.adoptFd(owned).close() }
        var started = false
        try {
            if (!inputCleanupFailed.get()) {
                val callback = if (fd == 0) null else object : TunInterface {
                    override fun protect(fd: Int): Boolean = runCatching { protect(fd) }
                        .getOrElse {
                            Log.e("Core", "socket 保护回调失败")
                            false
                        }

                    override fun resolverProcess(
                        protocol: Int,
                        source: String,
                        target: String,
                        uid: Int
                    ): String = runCatching {
                        resolverProcess(
                            protocol,
                            parseInetSocketAddress(source),
                            parseInetSocketAddress(target),
                            uid
                        )
                    }.getOrElse {
                        Log.e("Core", "进程解析回调失败")
                        ""
                    }
                }
                started = startNativeTun(lease, callback)
            }
        } catch (_: Throwable) {
            Log.e("Core", "TUN 启动调用失败")
        } finally {
            if (!lease.closeUnclaimed()) inputCleanupFailed.set(true)
        }
        return started && !inputCleanupFailed.get()
    }

    fun suspended(value: Boolean) {
        runCatching {
            Log.d("Core", "suspended called with value: $value")
            suspend(if (value) 1 else 0)
            Log.d("Core", "suspend JNI call completed")
        }.onFailure {
            Log.e("Core", "TUN 挂起调用失败")
        }
    }
}
