module protocol.ezsp;

import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.string;

import manager.console.command;
import manager.console.function_command : FunctionCommandState;
import manager.console.session;
import manager.plugin;

import protocol.ezsp.client;

import router.stream;

nothrow @nogc:


class EZSPProtocolModule : Plugin
{
    mixin RegisterModule!"protocol.ezsp";

    class Instance : Plugin.Instance
    {
        mixin DeclareInstance;

        Map!(const(char)[], EZSPClient) clients;

        override void init()
        {
            app.console.registerCommand!client_add("/protocol/ezsp/client", this, "add");
        }

        override void update() nothrow @nogc
        {
            foreach(name, client; clients)
                client.update();
        }

        void client_add(Session session, const(char)[] name, const(char)[] stream) nothrow @nogc
        {
            auto mod_stream = app.moduleInstance!StreamModule;

            // is it an error to not specify a stream?
            assert(stream, "'stream' must be specified");

            Stream s = mod_stream.getStream(stream);
            if (!s)
            {
                session.writeLine("Stream does not exist: ", stream);
                return;
            }

            if (name.empty)
                mod_stream.generateStreamName("serial-stream");

            NoGCAllocator a = app.allocator;

            String n = name.makeString(a);
            EZSPClient client = a.allocT!EZSPClient(n.move, s);
            clients.insert(client.name[], client);

//            writeInfof("Create Serial stream '{0}' - device: {1}@{2}", name, device, params.baudRate);
        }
    }
}
