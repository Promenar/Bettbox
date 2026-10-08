package com.appshub.bettbox

// 身份比对不授予启动权限，不把配置版本或Flutter engine代次当作库实例身份。
object NativeRuntimeIdentity {
    const val MAX_EPOCH = 9007199254740991L

    fun confirm(expected: Any?, readStatus: () -> String): Boolean {
        val epoch = when (expected) {
            is Long -> expected
            is Int -> expected.toLong()
            else -> return false
        }
        if (epoch <= 1L || epoch > MAX_EPOCH) return false
        return runCatching {
            val status = NativeConfigProtocol.parse(readStatus())
            status.epoch == epoch && !status.blocked && status.outcome != NativeConfigOutcome.UNKNOWN
        }.getOrDefault(false)
    }
}
