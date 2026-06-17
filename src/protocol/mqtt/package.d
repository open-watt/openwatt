module protocol.mqtt;

import manager;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.mqtt.binding;
import protocol.mqtt.broker;
import protocol.mqtt.client;
import protocol.mqtt.codec;

nothrow @nogc:


class MQTTModule : Module
{
    mixin DeclareModule!"protocol.mqtt";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!ProtocolLevel();

        g_app.console.register_collection!MQTTBroker();
        g_app.console.register_collection!MQTTClient();
        g_app.console.register_collection!MQTTBinding();
    }

    override void update()
    {
        Collection!MQTTBroker().update_all();
        Collection!MQTTClient().update_all();
    }
}
