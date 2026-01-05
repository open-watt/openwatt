module protocol.goodwe;

import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.meta.nullable;
import urt.result;
import urt.socket;
import urt.string;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;
import manager.sampler;

import protocol.goodwe.aa55;
import protocol.goodwe.sampler;

nothrow @nogc:


class GoodWeModule : Module
{
    mixin DeclareModule!"protocol.goodwe";
nothrow @nogc:

    Collection!AA55Client clients;
    Socket aa55_socket;

    override void init()
    {
        g_app.console.register_collection("/protocol/goodwe/aa55", clients);
        g_app.console.register_command!device_add("/protocol/goodwe/device", this, "add");

        // Create socket for AA55 clients
        Socket socket;
        Result r = create_socket(AddressFamily.ipv4, SocketType.datagram, Protocol.udp, socket);
        if (!r)
        {
            writeError("goodwe: failed to create AA55 socket: ", r);
            return;
        }

        r = socket.set_socket_option(SocketOption.non_blocking, true);
        if (!r)
        {
            socket.close();
            writeError("goodwe: failed to set non-blocking on AA55: ", r);
            return;
        }

        InetAddress bind_addr = InetAddress(IPAddr.any, 0);
        r = bind(socket, bind_addr);
        if (!r)
        {
            socket.close();
            writeError("goodwe: failed to bind AA55 socket: ", r);
            return;
        }

        aa55_socket = socket;
    }

    override void pre_update()
    {
        poll_aa55();

        clients.update_all();
    }

    void poll_aa55()
    {
        if (!aa55_socket)
            return;

        ubyte[1024] buffer = void;
        size_t bytes;
        InetAddress sender;

        while (true)
        {
            SysTime now = getSysTime();
            Result r = aa55_socket.recvfrom(buffer, MsgFlags.none, &sender, &bytes);
            if (!r)
            {
                if (r.socket_result() != SocketResult.would_block)
                {
                    // TODO: should we do anything?
                    //       recreate the socket? back-off for a while?
                    writeWarning("goodwe: recvfrom error: ", r);
                }
                break;
            }
            if (bytes == 0)
                continue; // degenerate zero-length packet?

            foreach (ref c; clients.values)
            {
                if (c.match_server(sender))
                {
                    c.incoming_message(buffer[0 .. bytes], now);
                    break;
                }
            }
        }
    }

    void device_add(Session session, const(char)[] id, AA55Client aa55_client, Nullable!(const(char)[]) name)
    {
        import urt.file;
        import urt.string.format;
        import manager.device;
        import manager.element;
        import manager.profile;

        const(char)[] profileName = aa55_client.profile;

        void[] file = load_file(tconcat("conf/goodwe_profiles/", profileName, ".conf"), g_app.allocator);
        if (!file)
        {
            session.write_line("Profile file not found: '", profileName, "'");
            return;
        }
        scope(exit) g_app.allocator.free(file);

        Profile* profile = parse_profile(cast(char[])file, g_app.allocator);
        if (!profile)
        {
            session.write_line("Failed to load profile: '", profileName, "'");
            return;
        }
        scope(exit) g_app.allocator.freeT(profile);

        // create a sampler for this modbus server...
        GoodWeSampler sampler = g_app.allocator.allocT!GoodWeSampler(aa55_client);

        Device device = create_device_from_profile(*profile, aa55_client.model[], id, name ? name.value : null, (Device device, Element* e, ref const ElementDesc desc, ubyte) {
            assert(desc.type == ElementType.aa55);
            ref const ElementDesc_AA55 aa55 = profile.get_aa55(desc.element);

            // write a null value of the proper type
            ubyte[256] tmp = void;
            tmp[0 .. aa55.value_desc.data_length] = 0;
            e.value = sample_value(tmp.ptr, aa55.value_desc);

            // record samper data...
            sampler.add_element(e, desc, aa55);
            device.sample_elements ~= e; // TODO: remove this?
        });
        if (!device)
        {
            session.write_line("Failed to create device '", id, "'");
            return;
        }
        device.samplers ~= sampler;
    }
}
