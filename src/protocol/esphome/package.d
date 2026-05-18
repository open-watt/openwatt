module protocol.esphome;

import manager;
import manager.collection;
import manager.plugin;

import protocol.esphome.client;
import protocol.esphome.protobuf;
import protocol.esphome.sampler;

nothrow @nogc:


mixin LoadProtobuf!"protocol/esphome/api.proto";


class ESPHomeModule : Module
{
    mixin DeclareModule!"protocol.esphome";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!ESPHomeClient();
        g_app.console.register_collection!ESPHomeBinding();
    }

    override void update()
    {
        Collection!ESPHomeClient().update_all();
    }
}
