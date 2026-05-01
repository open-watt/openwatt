module protocol.snmp;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

public import protocol.snmp.asn1;
public import protocol.snmp.oid;
public import protocol.snmp.pdu;
public import protocol.snmp.client;
public import protocol.snmp.agent;

nothrow @nogc:


class SNMPModule : Module
{
    mixin DeclareModule!"protocol.snmp";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!SNMPClient();
        g_app.console.register_collection!SNMPAgent();
    }

    override void update()
    {
        Collection!SNMPClient().update_all();
        Collection!SNMPAgent().update_all();
    }
}
