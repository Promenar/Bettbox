package com.appshub.bettbox

// 公开虚构JSON调用生产parser；不触发JNI、网络、TUN或系统权限。
object NativeConfigProtocolFixture {
    private var cases = 0
    private var failed = 0

    @JvmStatic
    fun main(args: Array<String>) {
        cases = 0
        failed = 0
        case { appliedReceiptUsesImmutableOptions() }
        strictSchemaAndNumbers()
        outcomesAndCombinations()
        stringsOptionsAndBudgets()
        tunReservationReceipts()
        runtimeIdentity()
        serviceRuntimeAdmission()
        println("cases=$cases, failed=$failed")
        check(failed == 0) { "配置回执fixture失败" }
    }

    private fun case(run: () -> Unit) {
        cases++
        try { run() } catch (_: Exception) { failed++ }
    }

    private fun receipt(
        outcome: String = "applied", phase: String = "applied", epoch: String = "1",
        revision: String = "2", attempted: String = "2", generation: String = "3",
        configured: String = "true", blocked: String = "false",
        options: String = "{}", error: String = "",
    ) = """{"outcome":"$outcome","phase":"$phase","epoch":$epoch,"configRevision":$revision,"attemptedRevision":$attempted,"stateGeneration":$generation,"configured":$configured,"blocked":$blocked,"options":$options,"errorCode":"$error"}"""

    private fun reject(input: String) = case {
        var rejected = false
        try { NativeConfigProtocol.parse(input) } catch (error: NativeConfigProtocolException) {
            check(error.message == "配置回执无效")
            check(error.cause == null)
            rejected = true
        }
        check(rejected)
    }

    private fun strictSchemaAndNumbers() {
        reject(receipt().replace("\"epoch\":1", "\"epoch\":1,\"epoch\":2"))
        reject(receipt().replace("\"epoch\":1", "\"epoch\":1,\"\\u0065poch\":2"))
        reject(receipt().replace("\"epoch\":1", "\"epoch\":1,\"extra\":0"))
        reject(receipt().replace(",\"errorCode\":\"\"", ""))
        reject("null")
        reject("[]")
        reject(receipt() + " {}")
        reject(receipt() + " true")
        reject("/*公开注释*/" + receipt())
        for (bad in listOf("\"1\"", "1.0", "1e0", "-1", "-0", "01", "9223372036854775808", "null", "true")) {
            reject(receipt(epoch = bad))
        }
        reject(receipt(epoch = "0"))
        for (field in listOf("configRevision", "attemptedRevision", "stateGeneration")) {
            for (bad in listOf("\"2\"", "2.5", "2e0", "-1", "9223372036854775808")) {
                val original = if (field == "stateGeneration") "3" else "2"
                reject(receipt().replace("\"$field\":$original", "\"$field\":$bad"))
            }
        }
        case {
            val value = NativeConfigProtocol.parse(receipt(epoch = "9223372036854775807"))
            check(value.epoch == Long.MAX_VALUE)
        }
        reject(receipt(configured = "\"true\""))
        reject(receipt(blocked = "null"))
    }

    private fun outcomesAndCombinations() {
        case {
            val value = NativeConfigProtocol.parse(receipt("staged", "staged", revision = "0", attempted = "0",
                configured = "false", options = "null"))
            check(value.outcome == NativeConfigOutcome.STAGED && value.optionsCanonicalJson == null)
        }
        case {
            val value = NativeConfigProtocol.parse(receipt("unknown", "entered", blocked = "true",
                options = "null", error = "configApplyFailed"))
            check(value.blocked && value.outcome == NativeConfigOutcome.UNKNOWN)
        }
        case {
            val value = NativeConfigProtocol.parse(receipt("rejected", "notEntered", blocked = "true",
                options = "null", error = "coordinatorBlocked"))
            check(value.blocked && value.configured && value.optionsCanonicalJson == null)
        }
        for (phase in listOf("entered", "notEntered", "staged")) reject(receipt(phase = phase))
        reject(receipt(configured = "false"))
        reject(receipt(blocked = "true"))
        reject(receipt(revision = "0", attempted = "0"))
        reject(receipt(attempted = "3"))
        reject(receipt(options = "null"))
        reject(receipt(options = "[]"))
        reject(receipt(error = "configApplyFailed"))
        reject(receipt("staged", "staged", revision = "0", attempted = "0", generation = "0", configured = "false", options = "null"))
        reject(receipt("staged", "staged", revision = "0", attempted = "1", configured = "false", options = "null"))
        reject(receipt("staged", "staged", revision = "0", attempted = "0", configured = "true", options = "null"))
        reject(receipt("unknown", "entered", blocked = "false", options = "null", error = "configApplyFailed"))
        reject(receipt("unknown", "notEntered", blocked = "true", options = "null", error = "configApplyFailed"))
        reject(receipt("unknown", "entered", blocked = "true", options = "null"))
        reject(receipt("unknown", "entered", blocked = "true", options = "null", error = "PublicArbitraryDetail"))
        reject(receipt("rejected", "entered", options = "null", error = "invalidPayload"))
        reject(receipt("rejected", "notEntered", error = "invalidPayload"))
        for (code in listOf("coordinatorBlocked", "configApplyFailed", "configPrepareFailed", "coreNotInitialized",
            "initialStateMissing", "initialCompositeAfterConfig", "invalidKind", "invalidPayload", "legacyConfigPresent",
            "optionsSnapshotFailed", "payloadTooLarge", "receiptEncodingFailed", "revisionOverflow", "staleEpoch",
            "staleRevision", "stateApplyFailed", "updateApplyFailed", "updateBeforeConfig", "unconfigured")) {
            case { check(NativeConfigProtocol.parse(receipt("rejected", "notEntered", options = "null", error = code)).errorCode == code) }
        }
        reject(receipt("rejected", "notEntered", options = "null", error = "coordinatorUnavailable"))
    }

    private fun stringsOptionsAndBudgets() {
        reject(receipt(options = """{"nested":{"value":1,"value":2}}"""))
        reject(receipt(options = """{"nested":[{"value":1,"value":2}]}"""))
        reject(receipt(options = """{"value":NaN}"""))
        reject(receipt(options = """{"value":1e999}"""))
        reject(receipt(options = """{"value":"bad\'escape"}"""))
        reject(receipt(options = "{\"value\":\"raw\nnewline\"}"))
        reject(receipt(options = """{"value":"\uD800"}"""))
        case {
            val value = NativeConfigProtocol.parse(receipt(options = """{"value":"公开\u914D\u7F6E\n\uD83D\uDE00","nested":[true,null,1.25]}"""))
            val snapshot = checkNotNull(value.optionsCanonicalJson)
            check(snapshot.contains("公开配置") && snapshot.contains("\\n"))
            NativeConfigProtocol.parse(receipt(options = """{"value":"另一公开配置"}"""))
            check(value.optionsCanonicalJson == snapshot)
        }
        case {
            val nested = "[".repeat(62) + "0" + "]".repeat(62)
            check(NativeConfigProtocol.parse(receipt(options = "{\"value\":$nested}")).configured)
        }
        val tooDeep = "[".repeat(63) + "0" + "]".repeat(63)
        reject(receipt(options = "{\"value\":$tooDeep}"))
        reject(receipt(options = "{\"value\":\"" + "x".repeat(NativeConfigProtocol.MAX_INPUT_BYTES) + "\"}"))
        // UTF-8字节预算不能由UTF-16字符数代替。
        reject(receipt(options = "{\"value\":\"" + "公".repeat(NativeConfigProtocol.MAX_INPUT_BYTES / 3 + 1) + "\"}"))
    }

    private fun tunReservationReceipts() {
        case {
            val value = NativeConfigProtocol.parse(receipt("rejected", "notEntered", options = "null", error = "tunConfigurationReserved"))
            check(value.outcome == NativeConfigOutcome.REJECTED && !value.blocked && value.configRevision == 2L)
            check(value.optionsCanonicalJson == null)
        }
        case {
            val value = NativeConfigProtocol.parse(receipt("unknown", "entered", blocked = "true", options = "null", error = "tunCleanupUnknown"))
            check(value.outcome == NativeConfigOutcome.UNKNOWN && value.blocked && value.configRevision == 2L)
            check(value.attemptedRevision == 2L && value.optionsCanonicalJson == null)
        }
        reject(receipt("unknown", "entered", blocked = "false", options = "null", error = "tunCleanupUnknown"))
        reject(receipt("unknown", "notEntered", blocked = "true", options = "null", error = "tunCleanupUnknown"))
        reject(receipt("rejected", "notEntered", options = "{}", error = "tunConfigurationReserved"))
        reject(receipt("rejected", "notEntered", options = "null", error = "invalidTunReservation"))
        reject(receipt("unknown", "entered", blocked = "true", options = "null", error = "tunConfigurationReserved"))
        reject(receipt("rejected", "notEntered", blocked = "true", options = "null", error = "tunConfigurationReserved"))
        reject(receipt("rejected", "notEntered", attempted = "3", options = "null", error = "tunConfigurationReserved"))
        reject(receipt("rejected", "notEntered", options = "null", error = "tunCleanupUnknown"))
        reject(receipt("unknown", "entered", configured = "false", blocked = "true", options = "null", error = "tunCleanupUnknown"))
        reject(receipt("unknown", "entered", attempted = "3", blocked = "true", options = "null", error = "tunCleanupUnknown"))
    }

    private fun serviceRuntimeAdmission() {
        case {
            val gate = ServiceRuntimeAdmission<Any>()
            val engine = Any()
            val currentMessenger = Any()
            val olderMessenger = Any()
            check(!gate.reject(null, currentMessenger) { currentMessenger })
            check(!gate.reject(engine, olderMessenger) { currentMessenger })
            check(!gate.isRejected(engine))
            check(gate.reject(engine, currentMessenger) { currentMessenger })
            check(gate.isRejected(engine))
            val laterEngine = Any()
            check(!gate.isRejected(laterEngine))
            check(!gate.reject(laterEngine, currentMessenger) { olderMessenger })
            check(!gate.isRejected(laterEngine))
            gate.clear()
            check(!gate.isRejected(engine))
        }
    }

    private fun runtimeIdentity() {
        case { check(NativeRuntimeIdentity.confirm(2) { receipt(epoch = "2") }) }
        case { check(NativeRuntimeIdentity.confirm(NativeRuntimeIdentity.MAX_EPOCH) { receipt(epoch = "9007199254740991") }) }
        for (bad in listOf<Any?>(null, 1, 0L, -1L, 9007199254740992L, "2", 2.0, true)) {
            case {
                var read = false
                check(!NativeRuntimeIdentity.confirm(bad) { read = true; receipt(epoch = "2") })
                check(!read)
            }
        }
        case { check(!NativeRuntimeIdentity.confirm(2) { receipt(epoch = "3") }) }
        case { check(!NativeRuntimeIdentity.confirm(2) { receipt(epoch = "2").replace("\"epoch\":2", "\"epoch\":2,\"epoch\":2") }) }
        case { check(!NativeRuntimeIdentity.confirm(2) { receipt("unknown", "entered", epoch = "2", blocked = "true", options = "null", error = "coordinatorBlocked") }) }
        case { check(!NativeRuntimeIdentity.confirm(2) { throw IllegalStateException("公开读取失败") }) }
        case { check(!NativeRuntimeIdentity.confirm(2) { throw UnsatisfiedLinkError("公开库初始化失败") }) }
    }

    private fun appliedReceiptUsesImmutableOptions() {
        val input = """{"outcome":"applied","phase":"applied","epoch":1,"configRevision":2,"attemptedRevision":2,"stateGeneration":3,"configured":true,"blocked":false,"options":{"mtu":1500,"label":"公开配置"},"errorCode":""}"""
        val receipt = NativeConfigProtocol.parse(input)
        check(receipt.outcome == NativeConfigOutcome.APPLIED)
        check(receipt.phase == NativeConfigPhase.APPLIED)
        check(receipt.epoch == 1L && receipt.configRevision == 2L)
        check(receipt.attemptedRevision == 2L && receipt.stateGeneration == 3L)
        check(receipt.configured && !receipt.blocked)
        check(receipt.errorCode.isEmpty())
        check(receipt.optionsCanonicalJson == """{"mtu":1500,"label":"公开配置"}""")
    }
}
