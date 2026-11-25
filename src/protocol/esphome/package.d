module protocol.esphome;

import manager;
import manager.collection;
import manager.plugin;

import protocol.esphome.client;
import protocol.esphome.binding;

import tools.protobuf;

nothrow @nogc:


mixin LoadProtobuf!"protocol/esphome/api.proto";


struct ESPHomeModule
{
    mixin DeclareStaticModule!"protocol.esphome";
nothrow @nogc:

    static void init()
    {
        g_app.console.register_collection!ESPHomeClient();
        g_app.console.register_collection!ESPHomeBinding();
    }

    static void update()
    {
        Collection!ESPHomeClient().update_all();
    }
}
