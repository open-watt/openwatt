module protocol.goodwe;

import urt.conv;
import urt.inet;
import urt.log;
import urt.meta.nullable;
import urt.result;
import urt.socket;
import urt.string;

import manager;
import manager.collection;
import manager.console.session : Session;
import manager.config : ConfItem;
import manager.plugin;
import manager.profile;
import manager.sample : desc_by_index;
import manager.series : ValueType;
import manager.sample.spec : stream_be_context;

import protocol.goodwe.aa55;
import protocol.goodwe.client;
import protocol.goodwe.binding;
import protocol.goodwe.server;
import protocol.goodwe.message;
import protocol.goodwe.control;
import protocol.goodwe.codec : register_goodwe_encodings;
import protocol.goodwe.module_config : goodwe_module_commit;

nothrow @nogc:


package __gshared uint aa55_section_kind;
package __gshared uint goodwe_register_section_kind;
package __gshared uint goodwe_rtu_section_kind;
package __gshared uint goodwe_module_section_kind;

package bool goodwe_section(uint kind)
{
    return kind == aa55_section_kind || kind == goodwe_register_section_kind ||
        kind == goodwe_rtu_section_kind || kind == goodwe_module_section_kind;
}

final class GoodWeModule : Module, ProfileSections
{
    mixin DeclareModule!"protocol.goodwe";
nothrow @nogc:

    Socket aa55_socket;

    override void init()
    {
        register_goodwe_encodings();
        aa55_section_kind = register_profile_section("aa55", this);
        goodwe_register_section_kind = register_profile_section("goodwe-register", this);
        goodwe_rtu_section_kind = register_profile_section("goodwe-rtu", this);
        goodwe_module_section_kind = register_profile_section("goodwe-module", this);

        g_app.console.register_collection!GoodWeClient();
        g_app.console.register_collection!GoodWeBinding();
        g_app.console.register_collection!GoodWeControlBinding();
        g_app.console.register_collection!GoodWeServer();
        g_app.console.register_command!(server_reply, "reply")(GoodWeServer.path, this);
        g_app.console.register_command!(server_clear_replies, "clear-replies")(GoodWeServer.path, this);
        g_app.console.register_command!(client_send, "send")(GoodWeClient.path, this);
        g_app.console.register_command!(client_request, "request")(GoodWeClient.path, this);
        g_app.console.register_command!(client_received, "received")(GoodWeClient.path, this);
        g_app.console.register_command!(server_requests, "requests")(GoodWeServer.path, this);
        g_app.console.register_command!(server_respond, "respond")(GoodWeServer.path, this);
        g_app.console.register_command!(server_answer, "answer")(GoodWeServer.path, this);
        g_app.console.register_command!(server_relay, "relay")(GoodWeServer.path, this);
        g_app.console.register_command!(server_raw_reply, "raw-reply")(GoodWeServer.path, this);

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

    void client_send(Session session, GoodWeClient client, ubyte[] data)
    {
        if (!client)
            return session.write_line("client not found");
        if (const(char)[] error = client.transmit_raw(data))
            session.write_line(error);
        else
            session.write_line("sent; inspect received or /log for the response");
    }

    void client_request(Session session, GoodWeClient client, ubyte fn,
        Nullable!String wire, Nullable!ubyte control, Nullable!ushort address,
        Nullable!ushort count, Nullable!ushort value, Nullable!ubyte unit,
        Nullable!ubyte source, Nullable!ubyte destination, Nullable!(ubyte[]) data)
    {
        const(char)[] carrier = wire ? wire.value[] : "aa55";
        const(ubyte)[] payload = data ? data.value : null;
        if (fn >= 128)
            return session.write_line("function must be below128");
        ubyte[1032] buffer = void;
        size_t length;
        if (carrier == "aa55")
        {
            if (payload.length > 255)
                return session.write_line("AA55 payload must be <=255 bytes");
            AA55Message message = AA55Message(payload, source ? source.value : 0xC0,
                destination ? destination.value : 0x7F, control ? control.value : 1, fn);
            length = message.encode(buffer);
        }
        else if (carrier == "module")
        {
            if (payload.length > 1024)
                return session.write_line("module payload must be <=1024 bytes");
            if (control && control.value != 1 && control.value != 2)
                return session.write_line("module control must be family1 or2");
            GoodWeModuleMessage message = GoodWeModuleMessage(payload, fn, control ? control.value : 1);
            length = message.encode(buffer);
        }
        else if (carrier == "modbus")
        {
            if (!address || (fn != 3 && fn != 4 && fn != 6 && fn != 16))
                return session.write_line("Modbus requires address and function3,4,6 or16");
            ushort quantity = fn == 6 ? value ? value.value : 0 : count ? count.value : 1;
            if (((fn == 3 || fn == 4) && (!quantity || quantity > 125 || payload.length)) ||
                (fn == 6 && (!value || payload.length)) ||
                (fn == 16 && (!quantity || quantity > 123 || payload.length != quantity * 2)))
                return session.write_line("invalid Modbus count, value or data length");
            ubyte[251] body = void;
            body[0] = cast(ubyte)(address.value >> 8);
            body[1] = cast(ubyte)address.value;
            body[2] = cast(ubyte)(quantity >> 8);
            body[3] = cast(ubyte)quantity;
            size_t body_length = 4;
            if (fn == 16)
            {
                body[4] = cast(ubyte)payload.length;
                body[5 .. 5 + payload.length] = payload;
                body_length = 5 + payload.length;
            }
            GoodWeModbusMessage message = GoodWeModbusMessage(body[0 .. body_length], unit ? unit.value : 0xF7, fn);
            length = message.encode(buffer);
        }
        else
            return session.write_line("wire must be aa55, module or modbus");
        if (!length)
            return session.write_line("unable to encode request");
        client_send(session, client, buffer[0 .. length]);
    }

    void client_received(Session session, GoodWeClient client)
    {
        if (!client)
            return session.write_line("client not found");
        session.write_line("data=", cast(const(void)[])client.experiment_response());
    }

    void server_requests(Session session, GoodWeServer server)
    {
        if (server) server.print_requests(session);
        else session.write_line("server not found");
    }

    void server_respond(Session session, GoodWeServer server, uint id, ubyte[] data)
    {
        if (!server) return session.write_line("server not found");
        if (const(char)[] error = server.respond(id, data)) session.write_line(error);
    }

    void server_relay(Session session, GoodWeServer server, uint id, GoodWeClient client)
    {
        if (!server) return session.write_line("server not found");
        const(ubyte)[] data = server.captured(id);
        if (!data.length) return session.write_line("request ID expired or not found");
        // The client copies nothing and sends synchronously before this capture can expire.
        if (!client) return session.write_line("client not found");
        if (const(char)[] error = client.transmit_raw(data)) session.write_line(error);
        else session.write_line("relayed upstream only; inspect received before responding to the app");
    }

    void server_answer(Session session, GoodWeServer server, uint id, ubyte[] data, Nullable!bool repeat)
    {
        if (!server) return session.write_line("server not found");
        if (const(char)[] error = server.answer(id, data, repeat ? repeat.value : false)) session.write_line(error);
    }

    void server_raw_reply(Session session, GoodWeServer server, ubyte[] request, ubyte[] response)
    {
        if (!server) return session.write_line("server not found");
        if (const(char)[] error = server.raw_reply(request, response)) session.write_line(error);
    }

    void server_reply(Session session, const(char)[] name, ubyte control, ubyte fn, ubyte[] data)
    {
        GoodWeServer server = Collection!GoodWeServer().get(name);
        if (!server)
            session.write_line("No AA55 server named '", name, "'");
        else if (const(char)[] error = server.set_reply(control, fn, data))
            session.write_line(error);
    }

    void server_clear_replies(Session session, const(char)[] name)
    {
        GoodWeServer server = Collection!GoodWeServer().get(name);
        if (server)
            server.clear_replies();
        else
            session.write_line("No AA55 server named '", name, "'");
    }

    void count_element(uint, ref const ConfItem item, ref ProfileSize size)
    {
        foreach (ref child; item.sub_items)
            if (child.name[] == "command")
            {
                const(char)[] payload = child.value;
                foreach (_; 0 .. 3)
                    payload.split!',';
                size.add_string(payload);
            }
    }

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
        if (taken != fn.length || ti > (kind == goodwe_register_section_kind || kind == goodwe_rtu_section_kind ? ushort.max : ubyte.max))
        {
            writeWarning("Invalid AA55 function code: ", fn);
            return false;
        }
        if (kind == goodwe_register_section_kind || kind == goodwe_rtu_section_kind)
        {
            aa55.address = cast(ushort)ti;
            aa55.function_code = kind == goodwe_register_section_kind ? 0x1A : 3;
            aa55.wire = kind == goodwe_register_section_kind ? GoodWeWire.aa55 : GoodWeWire.modbus;
        }
        else
        {
            aa55.function_code = cast(ubyte)ti;
            aa55.wire = kind == goodwe_module_section_kind ? GoodWeWire.module_ : GoodWeWire.aa55;
        }
        ti = offset.parse_uint_with_base(&taken);
        if (taken != offset.length || ti > ubyte.max)
        {
            writeWarning("Invalid AA55 value offset: ", offset);
            return false;
        }
        aa55.offset = cast(ubyte)ti;

        if (!b.compile_value(type, units, stream_be_context, aa55.desc, aa55.length))
            return false;
        if (aa55.length == 0 && (aa55.wire != GoodWeWire.module_ || desc_by_index(aa55.desc).fmt.type != ValueType.char_))
        {
            writeWarning("Unsized string requires a framed AA55 profile hook: ", b.element_id);
            aa55.desc = ushort.max;
            return false;
        }
        foreach (ref child; item.sub_items)
        {
            if (child.name[] == "record-bank")
            {
                if (kind != goodwe_rtu_section_kind || aa55.bank_count)
                    return false;
                const(char)[] bank = child.value;
                uint[3] values;
                foreach (index; 0 .. values.length)
                {
                    const(char)[] token = bank.split!',';
                    ulong value = token.parse_uint_with_base(&taken);
                    if (!token.length || taken != token.length || value > (index == 0 ? ushort.max : ubyte.max))
                        return false;
                    values[index] = cast(uint)value;
                }
                if (bank.length || !values[1] || values[1] > 125 || values[1] % 6 ||
                    !values[2] || values[2] > values[1] / 6 || values[0] + values[1] > 65536)
                    return false;
                aa55.bank_address = cast(ushort)values[0];
                aa55.bank_count = cast(ubyte)values[1];
                aa55.bank_limit = cast(ubyte)values[2];
                continue;
            }
            if (child.name[] == "record-type")
            {
                ulong value = child.value == "load" ? goodwe_load_record : child.value.parse_uint_with_base(&taken);
                if (kind != goodwe_rtu_section_kind || aa55.record_type != ubyte.max ||
                    (child.value != "load" && (taken != child.value.length || value > 6)))
                    return false;
                aa55.record_type = cast(ubyte)value;
                continue;
            }
            if (child.name[] == "request-byte")
            {
                ulong parameter = child.value.parse_uint_with_base(&taken);
                if (aa55.wire != GoodWeWire.module_ || aa55.address || taken != child.value.length || parameter > 255)
                    return false;
                aa55.address = cast(ushort)(parameter + 1);
                continue;
            }
            if (child.name[] == "command")
            {
                import urt.encoding : hex_decode;
                if (aa55.action || aa55.write_count || aa55.wire != GoodWeWire.aa55)
                    return false;
                const(char)[] command = child.value;
                ubyte[3] codes;
                foreach (ref code; codes)
                {
                    const(char)[] part = command.split!',';
                    ulong value = part.parse_uint_with_base(&taken);
                    if (!taken || taken != part.length || value > 255)
                        return false;
                    code = cast(ubyte)value;
                }
                ubyte[255] payload = void;
                if (codes[0] < 2 || codes[1] >= 128 || codes[2] < 128 || command.length > 510 ||
                    (command.length & 1) || hex_decode(command, payload) != command.length / 2)
                    return false;
                aa55.action_control = codes[0];
                aa55.action = uint(codes[1]) + 1;
                aa55.action_response = codes[2];
                aa55.action_payload = b.add_string(command);
                aa55.write_wire = GoodWeWire.aa55;
                aa55.write_address = cast(ushort)((uint(codes[0]) << 8) | codes[1]);
                aa55.write_count = 1;
                continue;
            }
            if (child.name[] == "action")
            {
                ulong value = child.value.parse_uint_with_base(&taken);
                if (aa55.action || taken != child.value.length || value > ushort.max)
                    return false;
                aa55.action = cast(uint)value + 1;
                continue;
            }
            if (child.name[] == "commit")
            {
                if ((child.value != "schedule" && child.value != "schedule-spn" && child.value != "prohibited-period" && child.value != "sequence" && child.value != "peak-period" && child.value != "reactive-mode" && child.value != "native-work-mode" && child.value != "load-period" && child.value != "battery-low745" && child.value != "module-network" && child.value != "module-password" && child.value != "legacy-work-mode" && child.value != "native-apn" && child.value != "native-alarm-page") || aa55.commit_format)
                    return false;
                aa55.commit_format = child.value == "schedule" ? GoodWeCommitFormat.legacy :
                    child.value == "schedule-spn" ? GoodWeCommitFormat.spn :
                    child.value == "peak-period" ? GoodWeCommitFormat.peak :
                    child.value == "reactive-mode" ? GoodWeCommitFormat.reactive :
                    child.value == "native-work-mode" ? GoodWeCommitFormat.native_mode :
                    child.value == "load-period" ? GoodWeCommitFormat.load :
                    child.value == "battery-low745" ? GoodWeCommitFormat.battery_low745 :
                    child.value == "module-network" ? GoodWeCommitFormat.module_network :
                    child.value == "module-password" ? GoodWeCommitFormat.module_password :
                    child.value == "legacy-work-mode" ? GoodWeCommitFormat.legacy_mode :
                    child.value == "native-apn" ? GoodWeCommitFormat.native_apn :
                    child.value == "native-alarm-page" ? GoodWeCommitFormat.native_alarm_page :
                    child.value == "prohibited-period" ? GoodWeCommitFormat.prohibited : GoodWeCommitFormat.sequence;
                continue;
            }
            if (child.name[] == "field")
            {
                if (aa55.wire != GoodWeWire.module_ || aa55.length != 0 || aa55.field_encoding != GoodWeFieldEncoding.raw)
                    return false;
                const(char)[] selector = child.value;
                const(char)[] encoding = selector.split!',';
                if (encoding != "csv" && encoding != "length-prefixed" && encoding != "status")
                    return false;
                ulong index = selector.parse_uint_with_base(&taken);
                if (!taken || taken != selector.length || index > ubyte.max || (encoding == "status" && index != 0))
                    return false;
                aa55.field_encoding = encoding == "csv" ? GoodWeFieldEncoding.csv : encoding == "status" ? GoodWeFieldEncoding.status : GoodWeFieldEncoding.length_prefixed;
                aa55.field_index = cast(ubyte)index;
                continue;
            }
            if (child.name[] == "invalid")
            {
                ulong raw = child.value.parse_uint_with_base(&taken);
                if (taken != child.value.length || aa55.reject_invalid || aa55.length > 4 ||
                    !desc_by_index(aa55.desc).fmt.is_scalar || raw > (ulong(1) << (aa55.length * 8)) - 1)
                {
                    writeWarning("Invalid GoodWe raw sentinel: ", b.element_id);
                    return false;
                }
                aa55.invalid_raw = cast(uint)raw;
                aa55.reject_invalid = true;
                continue;
            }
            if (child.name[] == "range")
            {
                const(char)[] range = child.value;
                const(char)[] low = range.split!','.unQuote;
                const(char)[] high = range.split!','.unQuote;
                if (range.length || !b.constrain_value(aa55.desc, low, high))
                {
                    writeWarning("Invalid GoodWe field range: ", b.element_id);
                    return false;
                }
                continue;
            }
            if (child.name[] != "write")
                continue;
            if (aa55.write_count)
                return false;
            const(char)[] write = child.value;
            const(char)[] carrier = write.split!',';
            if (carrier != "aa55" && carrier != "modbus")
            {
                writeWarning("GoodWe write carrier must be aa55 or modbus: ", b.element_id);
                return false;
            }
            aa55.write_wire = carrier == "aa55" ? GoodWeWire.aa55 : GoodWeWire.modbus;
            const(char)[] address = write.split!',';
            ulong value = address.parse_uint_with_base(&taken);
            if (taken != address.length || value > ushort.max)
                return false;
            aa55.write_address = cast(ushort)value;
            const(char)[] count = write.split!',';
            value = count.length ? count.parse_uint_with_base(&taken) : 1;
            if ((count.length && taken != count.length) || !value || value > 123)
                return false;
            aa55.write_count = cast(ubyte)value;
            const(char)[] start = write.split!',';
            value = start.length ? start.parse_uint_with_base(&taken) : 0;
            if ((start.length && taken != start.length) || value + aa55.length > aa55.write_count * 2 || write.length)
                return false;
            aa55.write_offset = cast(ubyte)value;
        }
        if (aa55.write_count && !desc_by_index(aa55.desc).fmt.is_scalar && aa55.commit_format != GoodWeCommitFormat.native_apn)
        {
            writeWarning("GoodWe writes require scalar fields: ", b.element_id);
            return false;
        }
        if (aa55.commit_format == GoodWeCommitFormat.legacy_mode)
        {
            if (aa55.wire != GoodWeWire.aa55 || aa55.function_code != 9 || aa55.offset != 66 ||
                aa55.length != 2 || aa55.action || aa55.write_count)
                return false;
            aa55.write_count = 1;
            aa55.write_wire = GoodWeWire.aa55;
            return true;
        }
        if (goodwe_module_commit(aa55.commit_format))
        {
            if (aa55.wire != GoodWeWire.module_ || aa55.length || aa55.action || aa55.write_count || aa55.offset)
                return false;
            aa55.write_count = 1;
            aa55.write_wire = GoodWeWire.module_;
            return true;
        }
        if (aa55.action && ((!aa55.action_control && aa55.write_wire != GoodWeWire.modbus) || aa55.write_count != 1 || aa55.length != 2 || aa55.commit_format))
            return false;
        if (aa55.commit_format && (aa55.write_wire != GoodWeWire.modbus ||
            (!goodwe_ordered_commit(aa55.commit_format) && aa55.write_count !=
             (aa55.commit_format == GoodWeCommitFormat.native_apn ? 25 : aa55.commit_format == GoodWeCommitFormat.prohibited ? 3 : aa55.commit_format == GoodWeCommitFormat.peak ? 5 : 6))))
            return false;
        if (aa55.commit_format == GoodWeCommitFormat.reactive && (aa55.write_count != 1 || aa55.length != 2 || aa55.write_offset))
            return false;
        if (aa55.commit_format == GoodWeCommitFormat.native_apn && (aa55.wire != GoodWeWire.modbus || aa55.address != 47041 ||
            aa55.write_address != 47041 || aa55.offset || aa55.write_offset || aa55.length != 48 ||
            !desc_by_index(aa55.desc).fmt.is_text))
            return false;
        if (aa55.commit_format == GoodWeCommitFormat.battery_low745 && (aa55.length != 2 || aa55.write_offset % 2))
            return false;
        if (aa55.commit_format == GoodWeCommitFormat.native_mode && (aa55.wire != GoodWeWire.modbus || aa55.address != 47000 ||
            aa55.write_address != 47000 || aa55.write_count != 1 || aa55.length != 2 || aa55.offset || aa55.write_offset))
            return false;
        if (aa55.commit_format == GoodWeCommitFormat.native_alarm_page && (aa55.wire != GoodWeWire.modbus || aa55.address != 47016 ||
            aa55.write_address != 47016 || aa55.write_count != 1 || aa55.length != 2 || aa55.offset || aa55.write_offset))
            return false;
        if (aa55.record_type != ubyte.max && aa55.write_count)
        {
            if (aa55.action ? aa55.write_address != uint(aa55.address) + 2 || aa55.write_count != 1 :
                aa55.write_address != aa55.address || aa55.write_count != (aa55.commit_format == GoodWeCommitFormat.peak ? 5 : 6))
                return false;
        }
        if (aa55.commit_format == GoodWeCommitFormat.load && aa55.record_type != goodwe_load_record)
            return false;
        if (aa55.bank_count && (!aa55.record_type || aa55.record_type == ubyte.max || aa55.action || aa55.write_count != 6 ||
            aa55.write_wire != GoodWeWire.modbus || aa55.write_address < aa55.bank_address ||
            uint(aa55.write_address) + 6 > uint(aa55.bank_address) + aa55.bank_count || (aa55.write_address - aa55.bank_address) % 6))
            return false;
        return true;
    }

    override void pre_update()
    {
        poll_aa55();

        Collection!GoodWeClient().update_all();
    }

    void poll_aa55()
    {
        if (!aa55_socket)
            return;

        ubyte[4096] buffer = void;
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

            foreach (c; Collection!GoodWeClient().values)
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
