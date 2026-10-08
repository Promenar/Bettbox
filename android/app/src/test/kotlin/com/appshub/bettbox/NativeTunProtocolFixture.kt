package com.appshub.bettbox

import com.google.gson.JsonParser
import java.io.File
import com.appshub.bettbox.core.OwnedTunCall
import com.appshub.bettbox.core.TunFDDisposition
import com.appshub.bettbox.core.TunFDSnapshot

object NativeTunProtocolFixture {
    private val identity=NativeTunIdentity(1,2,3)
    private val start="""{"operation":"start","request":{"Epoch":1,"ConfigRevision":2,"Generation":3},"outcome":"completed","phase":"completed","started":true,"stopped":false,"running":true,"blocked":false,"cleanupUnconfirmed":false,"retainsResource":true,"retainsLease":true,"resource":{"Epoch":1,"ConfigRevision":2,"Generation":3},"hasResource":true,"errorCode":""}"""
    private fun rejected(input:String) { check(runCatching{NativeTunProtocol.parse(input,identity,"start",true)}.isFailure) }
    @JvmStatic fun main(args:Array<String>) {
        val parsed=NativeTunProtocol.parse(start,identity,"start",true)
        check(parsed.started && parsed.resource==identity && parsed.outcome==NativeTunOutcome.COMPLETED)
        rejected(start.replace("\"blocked\":false","\"blocked\":true"))
        rejected(start.replace("\"retainsLease\":true","\"retainsLease\":false"))
        rejected(start.replace("\"stopped\":false","\"stopped\":true"))
        rejected(start.replace("\"phase\":\"completed\"","\"phase\":\"entered\""))
        rejected(start.replaceFirst("\"Generation\":3","\"Generation\":4"))
        rejected(start.replace("\"Epoch\":1","\"Epoch\":1.0"))
        rejected(start.replaceFirst("\"Epoch\":1","\"Epoch\":1,\"Epoch\":1"))
        rejected(start.replace("\"Generation\":3","\"Generation\":9223372036854775808"))
        rejected(start+"{}")
        rejected(start.replace("\"errorCode\":\"\"","\"errorCode\":\"private arbitrary error\""))
        rejected(start.replace("\"running\":true","\"running\":\"true\""))
        rejected(start.replace("\"operation\":\"start\"","\"operation\":\"st\\a rt\""))
        rejected(start.replace("\"operation\":\"start\"","\"operation\":\"\\uD800\""))
        rejected(start.dropLast(1)+",\"extra\":0}")
        val claimed=OwnedTunCall(start,TunFDSnapshot(TunFDDisposition.CLAIMED),false)
        check(NativeTunProtocol.completeStart(claimed,identity,true).started)
        for(disposition in listOf(TunFDDisposition.UNCLAIMED,TunFDDisposition.RELEASED,TunFDDisposition.UNKNOWN)) {
            val completion=NativeTunProtocol.completeStart(claimed.copy(input=TunFDSnapshot(disposition)),identity,true)
            check(completion.blocked && !completion.started && completion.receipt?.resource==identity)
        }
        check(NativeTunProtocol.completeStart(claimed.copy(bridgeBlocked=true),identity,true).blocked)
        check(NativeTunProtocol.completeStart(claimed.copy(receipt=null),identity,true).blocked)
        val nonVpn=start.replace("\"retainsResource\":true","\"retainsResource\":false").replace("\"retainsLease\":true","\"retainsLease\":false")
        check(NativeTunProtocol.parse(nonVpn,identity,"start",false).started)
        val stop=start.replace("\"operation\":\"start\"","\"operation\":\"stop\"").replace("\"started\":true","\"started\":false").replace("\"stopped\":false","\"stopped\":true").replace("\"running\":true","\"running\":false").replace("\"retainsResource\":true","\"retainsResource\":false").replace("\"retainsLease\":true","\"retainsLease\":false").replace("\"hasResource\":true","\"hasResource\":false").replace("\"resource\":{\"Epoch\":1,\"ConfigRevision\":2,\"Generation\":3}","\"resource\":{\"Epoch\":0,\"ConfigRevision\":0,\"Generation\":0}")
        check(NativeTunProtocol.parse(stop,identity,"stop",true).stopped)
        if(args.isNotEmpty()) {
            val cases=JsonParser.parseString(File(args[0]).readText()).asJsonArray
            check(cases.size()==9)
            for(value in cases) {
                val c=value.asJsonObject
                val expected=NativeTunIdentity(c["epoch"].asLong,c["revision"].asLong,c["generation"].asLong)
                val result=NativeTunProtocol.parse(c["receipt"].asString,expected,c["operation"].asString,c["vpn"].asBoolean)
                check(result.outcome.name.lowercase()==c["outcome"].asString)
            }
        }
        check(NativeTunProtocol.completeStop(stop,false,identity).stopped)
        check(!NativeTunProtocol.completeStop(stop,true,identity).stopped)
        println("{\"protocol_groups\":7,\"actual_Android\":false}")
    }
}
