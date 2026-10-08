package com.appshub.bettbox

import com.appshub.bettbox.core.OwnedTunCall
import com.appshub.bettbox.core.TunFDDisposition
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.StringReader

data class NativeTunIdentity(val epoch: Long, val configRevision: Long, val generation: Long)
enum class NativeTunOutcome { COMPLETED, REJECTED, FAILED, UNKNOWN }
data class NativeTunReceipt(
    val operation: String, val request: NativeTunIdentity, val outcome: NativeTunOutcome,
    val phase: String, val started: Boolean, val stopped: Boolean, val running: Boolean,
    val blocked: Boolean, val cleanupUnconfirmed: Boolean, val retainsResource: Boolean,
    val retainsLease: Boolean, val resource: NativeTunIdentity, val hasResource: Boolean,
    val errorCode: String,
)
data class NativeTunCompletion(val outcome: NativeTunOutcome, val blocked: Boolean, val receipt: NativeTunReceipt?) {
    val started: Boolean get() = outcome == NativeTunOutcome.COMPLETED && receipt?.started == true
    val stopped: Boolean get() = outcome == NativeTunOutcome.COMPLETED && receipt?.stopped == true
}
class NativeTunProtocolException : IllegalArgumentException("TUN回执无效")

object NativeTunProtocol {
    const val MAX_INPUT_BYTES = 16 * 1024
    const val MAX_DEPTH = 4
    private val fields = setOf("operation","request","outcome","phase","started","stopped","running","blocked","cleanupUnconfirmed","retainsResource","retainsLease","resource","hasResource","errorCode")
    private val errors = setOf("coordinatorBlocked","coreNotInitialized","staleEpoch","staleRevision","unconfigured","tunConfigurationReserved","tunCleanupUnknown","invalidTunReservation","invalidTunIdentity","tunModeMismatch","tunOwnershipMismatch","ownershipRejected","invalidFD","notReady","openFailed","openPanic","resourceCloseFailed","resourceClosePanic","inputCleanupFailed","inputCleanupPanic","releasePanic","internalPanic")
    private val integer = Regex("(?:0|[1-9][0-9]*)")
    private val number = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
    private sealed class Value {
        class ObjectValue(val members: LinkedHashMap<String, Value>) : Value()
        class ArrayValue(val values: List<Value>) : Value()
        class StringValue(val value: String) : Value()
        class NumberValue(val lexeme: String) : Value()
        class BoolValue(val value: Boolean) : Value()
        object NullValue : Value()
    }
    fun parse(input: String, request: NativeTunIdentity, operation: String, vpnRequired: Boolean): NativeTunReceipt {
        try {
            if (request.epoch<=0 || request.configRevision<=0 || request.generation<=0 || operation !in setOf("start","stop")) fail()
            if(input.length>MAX_INPUT_BYTES || input.toByteArray(Charsets.UTF_8).size>MAX_INPUT_BYTES) fail()
            validUnicode(input); strictStrings(input)
            val root=JsonReader(StringReader(input)).use { reader ->
                reader.isLenient=false
                val value=read(reader,0)
                if(reader.peek()!=JsonToken.END_DOCUMENT) fail()
                value as? Value.ObjectValue ?: fail()
            }
            if(root.members.keys!=fields) fail()
            val values=root.members
            fun text(name:String)=(values[name] as? Value.StringValue)?.value ?: fail()
            fun flag(name:String)=(values[name] as? Value.BoolValue)?.value ?: fail()
            fun identity(name:String):NativeTunIdentity {
                val members=(values[name] as? Value.ObjectValue)?.members ?: fail()
                if(members.keys!=setOf("Epoch","ConfigRevision","Generation")) fail()
                fun stamp(key:String):Long {
                    val lexeme=(members[key] as? Value.NumberValue)?.lexeme ?: fail()
                    if(!integer.matches(lexeme)) fail()
                    return lexeme.toLongOrNull() ?: fail()
                }
                return NativeTunIdentity(stamp("Epoch"),stamp("ConfigRevision"),stamp("Generation"))
            }
            if(text("operation")!=operation || identity("request")!=request) fail()
            val outcome=when(text("outcome")) {"completed"->NativeTunOutcome.COMPLETED;"rejected"->NativeTunOutcome.REJECTED;"failed"->NativeTunOutcome.FAILED;"unknown"->NativeTunOutcome.UNKNOWN;else->fail()}
            val phase=text("phase")
            if(phase !in setOf("notEntered","entered","completed")) fail()
            val started=flag("started");val stopped=flag("stopped");val running=flag("running")
            val blocked=flag("blocked");val cleanup=flag("cleanupUnconfirmed")
            val retainsResource=flag("retainsResource");val retainsLease=flag("retainsLease")
            val resource=identity("resource");val hasResource=flag("hasResource");val error=text("errorCode")
            if(operation=="start" && stopped || operation=="stop" && started) fail()
            if(hasResource) {if(resource.epoch<=0 || resource.configRevision<=0 || resource.generation<=0) fail()}
            else if(resource!=NativeTunIdentity(0,0,0)) fail()
            when(outcome) {
                NativeTunOutcome.COMPLETED -> {
                    if(phase!="completed" || blocked || cleanup || error.isNotEmpty()) fail()
                    if(operation=="start") {
                        if(!started || !running || !hasResource || resource!=request) fail()
                        if(vpnRequired && (!retainsResource || !retainsLease) || !vpnRequired && (retainsResource || retainsLease)) fail()
                    } else if(!stopped || running || hasResource || retainsResource || retainsLease) fail()
                }
                NativeTunOutcome.REJECTED -> if(phase!="notEntered" || started || stopped || blocked || cleanup || error !in errors) fail()
                NativeTunOutcome.FAILED -> if(operation!="start" || phase=="completed" || started || stopped || running || hasResource || retainsResource || retainsLease || blocked || cleanup || error !in errors) fail()
                NativeTunOutcome.UNKNOWN -> if(phase=="completed" || !blocked || error !in errors) fail()
            }
            return NativeTunReceipt(operation,request,outcome,phase,started,stopped,running,blocked,cleanup,retainsResource,retainsLease,resource,hasResource,error)
        } catch (_: Exception) { throw NativeTunProtocolException() }
    }

    // 本地RELEASED只能证明未领取输入关闭，不能配Go启动成功；CLAIMED也不证明Go已关闭。
    fun completeStart(call: OwnedTunCall, request: NativeTunIdentity, vpnRequired: Boolean): NativeTunCompletion {
        val receipt=runCatching { parse(call.receipt ?: throw NativeTunProtocolException(),request,"start",vpnRequired) }.getOrNull()
        val inputUnknown=call.input.disposition==TunFDDisposition.UNKNOWN || call.input.disposition==TunFDDisposition.UNCLAIMED
        val contradictory=receipt?.outcome==NativeTunOutcome.COMPLETED && call.input.disposition!=TunFDDisposition.CLAIMED
        val blocked=call.bridgeBlocked || receipt==null || receipt.blocked || inputUnknown || contradictory
        return NativeTunCompletion(if(blocked) NativeTunOutcome.UNKNOWN else receipt!!.outcome,blocked,receipt)
    }
    fun completeStop(raw:String?, bridgeBlocked:Boolean, request:NativeTunIdentity):NativeTunCompletion {
        val receipt=runCatching { parse(raw ?: throw NativeTunProtocolException(),request,"stop",false) }.getOrNull()
        val blocked=bridgeBlocked || receipt==null || receipt.blocked
        return NativeTunCompletion(if(blocked) NativeTunOutcome.UNKNOWN else receipt!!.outcome,blocked,receipt)
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

    private fun fail(): Nothing = throw NativeTunProtocolException()
}
