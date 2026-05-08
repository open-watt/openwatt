module protocol.mqtt;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.mqtt.broker;
import protocol.mqtt.sampler;

nothrow @nogc:

class MQTTModule : Module
{
    mixin DeclareModule!"protocol.mqtt";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!MQTTBroker();
        g_app.console.register_collection!MQTTBinding();
    }

    override void update()
    {
        Collection!MQTTBroker().update_all();
    }
}
