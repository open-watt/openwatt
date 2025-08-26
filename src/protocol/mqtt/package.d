module protocol.mqtt;

import urt.log;
import urt.mem.allocator;
import urt.string;

import manager.collection;
import manager.console;
import manager.plugin;

import protocol.mqtt.broker;

nothrow @nogc:

class MQTTModule : Module
{
    mixin DeclareModule!"protocol.mqtt";
nothrow @nogc:

    Collection!MQTTBroker brokers;

    override void init()
    {
        g_app.console.registerCollection("/protocol/mqtt/broker", brokers);
    }

    override void update()
    {
        brokers.updateAll();
    }
}


private:
