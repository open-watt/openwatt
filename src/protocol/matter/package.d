module protocol.matter;

import manager;
import manager.plugin;

public import protocol.matter.tlv;

nothrow @nogc:


class MatterProtocolModule : Module
{
    mixin DeclareModule!"protocol.matter";
nothrow @nogc:

    override void init()
    {
    }
}
