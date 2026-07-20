module protocol.goodwe;

import urt.conv;
import urt.inet;
import urt.log;
import urt.result;
import urt.socket;
import urt.string;

import manager;
import manager.collection;
import manager.config : ConfItem;
import manager.plugin;
import manager.profile;
import manager.sample.spec : stream_be_context;

import protocol.goodwe.aa55;
import protocol.goodwe.binding;

nothrow @nogc:


package __gshared uint aa55_section_kind;

class GoodWeModule : Module, ProfileSections
{
    mixin DeclareModule!"protocol.goodwe";
nothrow @nogc:

    Socket aa55_socket;

    override void init()
    {
        aa55_section_kind = register_profile_section("aa55", this);

        g_app.console.register_collection!AA55Client();
        g_app.console.register_collection!GoodWeBinding();

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

    uint element_size(uint)
        => cast(uint)ElementDesc_AA55.sizeof;

    void count_element(uint, ref const ConfItem, ref ProfileCosts) {}

    bool parse_element(uint kind, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        const(char)[] tail = item.value;
        ElementDesc_AA55* aa55 = cast(ElementDesc_AA55*)slot.ptr;
        *aa55 = ElementDesc_AA55.init;

        const(char)[] fn = tail.split!',';
        const(char)[] offset = tail.split!',';
        const(char)[] type = tail.split!','.unQuote;
        const(char)[] units = tail.split!','.unQuote;

        size_t taken;
        ulong ti = fn.parse_uint_with_base(&taken);
        if (taken != fn.length || ti > ubyte.max)
        {
            writeWarning("Invalid AA55 function code: ", fn);
            return false;
        }
        aa55.function_code = cast(ubyte)ti;
        ti = offset.parse_uint_with_base(&taken);
        if (taken != offset.length || ti > ubyte.max)
        {
            writeWarning("Invalid AA55 value offset: ", offset);
            return false;
        }
        aa55.offset = cast(ubyte)ti;

        if (!b.compile_value(type, units, stream_be_context, aa55.desc, aa55.length))
            return false;
        if (aa55.length == 0)
        {
            writeWarning("Unsized string requires a framed AA55 profile hook: ", b.element_id);
            aa55.desc = ushort.max;
            return false;
        }
        return true;
    }

    override void pre_update()
    {
        poll_aa55();

        Collection!AA55Client().update_all();
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
            MonoTime now = getTime();
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

            foreach (c; Collection!AA55Client().values)
            {
                if (c.match_server(sender))
                {
                    c.incoming_message(buffer[0 .. bytes], now);
                    break;
                }
            }
        }
    }

}
