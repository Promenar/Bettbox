package com.appshub.bettbox

import com.google.gson.GsonBuilder
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.StringReader

enum class NativeConfigOutcome { APPLIED, STAGED, REJECTED, UNKNOWN }

enum class NativeConfigPhase { NOT_ENTERED, ENTERED, APPLIED, STAGED }

// 仅保留不可变安全字段；options在具体adapter核验前不能作为运行授权。
data class NativeConfigReceipt(
    val outcome: NativeConfigOutcome,
    val phase: NativeConfigPhase,
    val epoch: Long,
    val configRevision: Long,
    val attemptedRevision: Long,
    val stateGeneration: Long,
    val configured: Boolean,
    val blocked: Boolean,
    val optionsCanonicalJson: String?,
    val errorCode: String,
)

class NativeConfigProtocolException : IllegalArgumentException("配置回执无效")

object NativeConfigProtocol {
    const val MAX_INPUT_BYTES = 16 * 1024 * 1024
    const val MAX_DEPTH = 64

    private val fields = setOf("outcome", "phase", "epoch", "configRevision", "attemptedRevision",
        "stateGeneration", "configured", "blocked", "options", "errorCode")
    private val errors = setOf("coordinatorBlocked", "configApplyFailed", "configPrepareFailed",
        "coreNotInitialized", "initialStateMissing", "initialCompositeAfterConfig", "invalidKind",
        "invalidPayload", "legacyConfigPresent", "optionsSnapshotFailed", "payloadTooLarge",
        "receiptEncodingFailed", "revisionOverflow", "staleEpoch", "staleRevision", "stateApplyFailed",
        "updateApplyFailed", "updateBeforeConfig", "unconfigured", "tunConfigurationReserved", "tunCleanupUnknown",
        "coreInitializeFailed", "initializationConflict", "legacyListenerPresent")
    private val integer = Regex("(?:0|[1-9][0-9]*)")
    private val number = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
    private val gson = GsonBuilder().disableHtmlEscaping().create()

    private sealed class Value {
        class ObjectValue(val members: LinkedHashMap<String, Value>) : Value()
        class ArrayValue(val values: List<Value>) : Value()
        class StringValue(val value: String) : Value()
        class NumberValue(val lexeme: String) : Value()
        class BoolValue(val value: Boolean) : Value()
        object NullValue : Value()
    }

    fun parse(input: String): NativeConfigReceipt {
        try {
            validUnicode(input)
            if (input.length > MAX_INPUT_BYTES || input.toByteArray(Charsets.UTF_8).size > MAX_INPUT_BYTES) fail()
            strictStrings(input)
            val root = JsonReader(StringReader(input)).use { reader ->
                reader.isLenient = false
                val value = read(reader, 0)
                if (reader.peek() != JsonToken.END_DOCUMENT) fail()
                value as? Value.ObjectValue ?: fail()
            }
            if (root.members.keys != fields) fail()
            val values = root.members
            fun text(name: String) = (values[name] as? Value.StringValue)?.value ?: fail()
            fun flag(name: String) = (values[name] as? Value.BoolValue)?.value ?: fail()
            fun stamp(name: String): Long {
                val lexeme = (values[name] as? Value.NumberValue)?.lexeme ?: fail()
                if (!integer.matches(lexeme)) fail()
                return lexeme.toLongOrNull() ?: fail()
            }
            val outcome = when (text("outcome")) {
                "applied" -> NativeConfigOutcome.APPLIED
                "staged" -> NativeConfigOutcome.STAGED
                "rejected" -> NativeConfigOutcome.REJECTED
                "unknown" -> NativeConfigOutcome.UNKNOWN
                else -> fail()
            }
            val phase = when (text("phase")) {
                "notEntered" -> NativeConfigPhase.NOT_ENTERED
                "entered" -> NativeConfigPhase.ENTERED
                "applied" -> NativeConfigPhase.APPLIED
                "staged" -> NativeConfigPhase.STAGED
                else -> fail()
            }
            val epoch = stamp("epoch")
            val revision = stamp("configRevision")
            val attempted = stamp("attemptedRevision")
            val generation = stamp("stateGeneration")
            if (epoch == 0L) fail()
            val configured = flag("configured")
            val blocked = flag("blocked")
            val error = text("errorCode")
            val options = values.getValue("options")
            when (outcome) {
                NativeConfigOutcome.APPLIED -> if (phase != NativeConfigPhase.APPLIED || !configured || blocked ||
                    revision == 0L || attempted != revision || options !is Value.ObjectValue || error.isNotEmpty()) fail()
                NativeConfigOutcome.STAGED -> if (phase != NativeConfigPhase.STAGED || configured || blocked ||
                    revision != 0L || attempted != 0L || generation == 0L || options !== Value.NullValue || error.isNotEmpty()) fail()
                NativeConfigOutcome.UNKNOWN -> if (phase != NativeConfigPhase.ENTERED || !blocked ||
                    options !== Value.NullValue || error !in errors) fail()
                NativeConfigOutcome.REJECTED -> if (phase != NativeConfigPhase.NOT_ENTERED ||
                    options !== Value.NullValue || error !in errors) fail()
            }
            if (error == "tunConfigurationReserved" && (outcome != NativeConfigOutcome.REJECTED || blocked ||
                    !configured || revision == 0L || attempted != revision)) fail()
            if (error == "tunCleanupUnknown" && (outcome != NativeConfigOutcome.UNKNOWN ||
                    !configured || revision == 0L || attempted != revision)) fail()
            val optionsJson = if (options is Value.ObjectValue) compact(options) else null
            if (optionsJson != null && optionsJson.toByteArray(Charsets.UTF_8).size > MAX_INPUT_BYTES) fail()
            return NativeConfigReceipt(outcome, phase, epoch, revision, attempted, generation, configured,
                blocked, optionsJson, error)
        } catch (_: Exception) {
            throw NativeConfigProtocolException()
        }
    }

    private fun read(reader: JsonReader, depth: Int): Value = when (reader.peek()) {
        JsonToken.BEGIN_OBJECT -> {
            if (depth >= MAX_DEPTH) fail()
            val members = linkedMapOf<String, Value>()
            reader.beginObject()
            while (reader.hasNext()) {
                val name = reader.nextName()
                validUnicode(name)
                if (members.containsKey(name)) fail()
                members[name] = read(reader, depth + 1)
            }
            reader.endObject()
            Value.ObjectValue(members)
        }
        JsonToken.BEGIN_ARRAY -> {
            if (depth >= MAX_DEPTH) fail()
            val values = mutableListOf<Value>()
            reader.beginArray()
            while (reader.hasNext()) values.add(read(reader, depth + 1))
            reader.endArray()
            Value.ArrayValue(values)
        }
        JsonToken.STRING -> Value.StringValue(reader.nextString().also { validUnicode(it) })
        JsonToken.NUMBER -> Value.NumberValue(reader.nextString().also {
            if (!number.matches(it) || it.toDoubleOrNull()?.isFinite() != true) fail()
        })
        JsonToken.BOOLEAN -> Value.BoolValue(reader.nextBoolean())
        JsonToken.NULL -> { reader.nextNull(); Value.NullValue }
        else -> fail()
    }

    // 紧凑重编码保留对象成员顺序，不将可变解析树交给消费者。
    private fun compact(value: Value): String = when (value) {
        is Value.ObjectValue -> value.members.entries.joinToString(",", "{", "}") { gson.toJson(it.key) + ":" + compact(it.value) }
        is Value.ArrayValue -> value.values.joinToString(",", "[", "]") { compact(it) }
        is Value.StringValue -> gson.toJson(value.value)
        is Value.NumberValue -> value.lexeme
        is Value.BoolValue -> value.value.toString()
        Value.NullValue -> "null"
    }

    private fun validUnicode(value: String) {
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (Character.isHighSurrogate(char)) {
                if (index + 1 >= value.length || !Character.isLowSurrogate(value[index + 1])) fail()
                index++
            } else if (Character.isLowSurrogate(char)) fail()
            index++
        }
    }

    // Gson严格模式仍允许部分非JSON字符串转义；在读取前收窄为JSON词法。
    private fun strictStrings(input: String) {
        var quoted = false
        var index = 0
        while (index < input.length) {
            val char = input[index]
            if (char == '"') {
                quoted = !quoted
            } else if (quoted && char == '\\') {
                index++
                if (index >= input.length) fail()
                when (input[index]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> Unit
                    'u' -> {
                        if (index + 4 >= input.length) fail()
                        for (offset in 1..4) if (input[index + offset] !in "0123456789abcdefABCDEF") fail()
                        index += 4
                    }
                    else -> fail()
                }
            } else if (quoted && char.code < 0x20) fail()
            index++
        }
        if (quoted) fail()
    }

    private fun fail(): Nothing = throw NativeConfigProtocolException()
}
