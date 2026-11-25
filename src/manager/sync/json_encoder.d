module manager.sync.json_encoder;

// JsonEncoder - text-frame encoding for operator / browser-facing sync.
//
// Wire shape: one JSON object per frame.
//   {"kind": "<verb>", ...kind-specific fields}
//
// Self-describing; one WebSocket text message or one datagram per frame.
// Name-based addressing on the wire: add_name binds a session handle to a
// name once, every other verb cites the handle. Local ids never travel.

import urt.array;
import urt.format.json;
import urt.log;
import urt.mem;
import urt.meta.enuminfo : enum_key_from_value, enum_from_key, VoidEnumInfo;
import urt.string;
import urt.time : SysTime;
import urt.variant;

import manager.base;
import manager.collection;
import manager.console.session : ClientFeatures;
import manager.element : Element;
import manager.series : Constraint, DataFormat, Scalar, SeriesKind, ValueType;
import manager.sync;
import manager.sync.encoder;
import manager.sync.peer;
import manager.value : append_json;


nothrow @nogc:


__gshared JsonEncoder g_json_encoder;


final class JsonEncoder : SyncEncoder
{
nothrow @nogc:

    alias log = Log!"sync.json";

    SyncModule sync;

    this(SyncModule sync)
    {
        this.sync = sync;
    }

    // Outbound: registry

    override void encode_add_name(SyncPeer peer, BaseObject obj)
    {
        begin_frame("add_name");
        _buf.append(",\"h\":", peer.introduce(obj));
        _buf.append(",\"name\":");
        write_str(obj.name[]);
        _buf.append(",\"type\":");
        write_str(obj.type[]);
        send_frame(peer);
    }

    // Outbound: mirror lifecycle

    override void encode_bind(SyncPeer peer, BaseObject obj, uint seq)
    {
        SyncHandle h = peer.handle_of(obj);
        debug assert(h != SyncPeer.invalid_handle, "bind without prior add_name");
        begin_frame("bind");
        _buf.append(",\"target\":", h);
        _buf.append(",\"type\":");
        write_str(obj.type[]);
        if (seq)
            _buf.append(",\"seq\":", seq);
        write_obj_props(obj);
        send_frame(peer);
    }

    override void encode_unbind(SyncPeer peer, CID target, uint seq)
    {
        begin_frame("unbind");
        _buf.append(",\"target\":", peer.handle_of(target));
        if (seq)
            _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    override void encode_create(SyncPeer peer, const(char)[] type, NamedArgument[] props, uint seq)
    {
        begin_frame("create");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"type\":");
        write_str(type);
        _buf.append(",\"props\":{");
        foreach (i, ref arg; props)
        {
            if (i)
                _buf ~= ',';
            write_str(arg.name[]);
            _buf ~= ':';
            write_variant(arg.value);
        }
        _buf ~= '}';
        send_frame(peer);
    }

    override void encode_destroy(SyncPeer peer, CID target, uint seq)
    {
        begin_frame("destroy");
        _buf.append(",\"target\":", peer.handle_of(target));
        if (seq)
            _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    // Outbound: state + property

    override void encode_state(SyncPeer peer, CID target, StateSignal sig)
    {
        begin_frame("state");
        _buf.append(",\"target\":", peer.handle_of(target));
        _buf.append(",\"signal\":\"", enum_key_from_value!StateSignal(sig), "\"");
        send_frame(peer);
    }

    override void encode_set(SyncPeer peer, BaseObject obj, size_t prop_index, uint seq)
    {
        auto props = obj.properties();
        if (prop_index >= props.length)
            return;
        auto p = props[prop_index];
        if (!p.get)
            return;

        begin_property_frame(peer, "set", obj.id, p.name[]);
        _buf.append(",\"value\":");
        Variant v = p.get(obj, *p);
        write_variant(v);
        finish_property_frame(peer, seq);
    }

    override void encode_set(SyncPeer peer, CID target, const(char)[] prop_name, ref const Variant value, uint seq)
    {
        begin_property_frame(peer, "set", target, prop_name);
        _buf.append(",\"value\":");
        write_variant(value);
        finish_property_frame(peer, seq);
    }

    override void encode_reset(SyncPeer peer, CID target, const(char)[] prop_name, uint seq)
    {
        begin_property_frame(peer, "reset", target, prop_name);
        finish_property_frame(peer, seq);
    }

    // Outbound: commands, errors, enums, subscriptions

    override void encode_cmd(SyncPeer peer, uint seq, const(char)[] text)
    {
        encode_text_command(peer, "cmd", seq, text);
    }

    override int encode_result(SyncPeer peer, uint seq, ref const Variant value, const(char)[] out_text)
    {
        begin_frame("result");
        _buf.append(",\"seq\":", seq);
        if (!value.isNull)
        {
            _buf.append(",\"value\":");
            write_variant(value);
        }
        _buf.append(",\"text\":");
        write_str(out_text);
        return send_frame(peer);
    }

    override void encode_error(SyncPeer peer, uint seq, const(char)[] text)
    {
        encode_text_command(peer, "error", seq, text);
    }

    override void encode_suggest(SyncPeer peer, uint seq, const(char)[] text)
    {
        encode_text_command(peer, "suggest", seq, text);
    }

    override void encode_suggestions(SyncPeer peer, uint seq, const(String)[] suggestions, const(char)[] completed)
    {
        begin_frame("suggestions");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"complete\":");
        write_str(completed);
        _buf.append(",\"suggestions\":[");
        foreach (i, ref s; suggestions)
        {
            if (i)
                _buf.append(",");
            write_str(s[]);
        }
        _buf.append("]");
        send_frame(peer);
    }

    override int encode_console(SyncPeer peer, uint seq, SyncConsoleEvent event, const(char)[] data = null, SyncConsoleTerminal terminal = SyncConsoleTerminal())
    {
        begin_frame("console");
        _buf.append(",\"seq\":", seq, ",\"event\":\"", enum_key_from_value!SyncConsoleEvent(event), '"');
        final switch (event)
        {
            case SyncConsoleEvent.open:
            case SyncConsoleEvent.terminal:
                _buf.append(",\"width\":", terminal.width, ",\"height\":", terminal.height,
                            ",\"features\":", ushort(terminal.features), ",\"terminal\":");
                write_str(terminal.type);
                break;
            case SyncConsoleEvent.input:
            case SyncConsoleEvent.output:
                _buf ~= ",\"data\":";
                write_str(data);
                break;
            case SyncConsoleEvent.close:
            case SyncConsoleEvent.closed:
                break;
        }
        return send_frame(peer);
    }

    // a text frame cannot be fragmented, and an escaped control byte takes six
    override size_t console_payload(SyncPeer peer) const
        => peer.send_limit > console_overhead ? (peer.send_limit - console_overhead) / 6 : 0;

    enum size_t console_overhead = `{"kind":"console","seq":4294967295,"event":"output","data":""}`.length;

    override void encode_sub(SyncPeer peer, const(char)[] pattern)
    {
        begin_frame("sub");
        _buf.append(",\"pattern\":");
        write_str(pattern);
        send_frame(peer);
    }

    override void encode_unsub(SyncPeer peer, const(char)[] pattern)
    {
        begin_frame("unsub");
        _buf.append(",\"pattern\":");
        write_str(pattern);
        send_frame(peer);
    }

    override void encode_enum_req(SyncPeer peer, const(char)[] type_name, uint seq)
    {
        begin_frame("enum_req");
        _buf.append(",\"type\":");
        write_str(type_name);
        _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    // Outbound: log streaming

    override void encode_log_sub(SyncPeer peer, Severity max_severity, bool off, const(char)[] tag)
    {
        begin_frame("log_sub");
        _buf.append(",\"severity\":\"", off ? "off" : enum_key_from_value!Severity(max_severity), "\"");
        if (tag.length)
        {
            _buf.append(",\"tag\":");
            write_str(tag);
        }
        send_frame(peer);
    }

    override bool encode_log(SyncPeer peer, const(char)[] line, bool loss_notice = false)
    {
        begin_frame("log");
        _buf.append(",\"msg\":");
        write_str(line);
        return peer.discard_log(_buf.length + 1, true, loss_notice) || send_frame(peer, TxQueue.log) >= 0;
    }

    override void encode_enum(SyncPeer peer, const(char)[] type_name, ref const Variant members, uint seq)
    {
        begin_frame("enum");
        _buf.append(",\"type\":");
        write_str(type_name);
        _buf.append(",\"seq\":", seq);
        if (!members.isNull)
        {
            _buf.append(",\"members\":");
            write_variant(members);
        }
        send_frame(peer);
    }

    // Outbound: time sync

    override void encode_time_req(SyncPeer peer, uint seq)
    {
        begin_frame("time_req");
        _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    override void encode_time_resp(SyncPeer peer, uint seq, ulong recv_ns, ulong xmit_ns, uint ver)
    {
        begin_frame("time_resp");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"recv\":", recv_ns);
        _buf.append(",\"xmit\":", xmit_ns);
        _buf.append(",\"ver\":", ver);
        send_frame(peer);
    }

    override void encode_time_push(SyncPeer peer, uint ver, long delta_ns)
    {
        begin_frame("time_push");
        _buf.append(",\"ver\":", ver);
        _buf.append(",\"delta\":", delta_ns);
        send_frame(peer);   // control: staleness corrupts collection timestamps until repaired
    }

    // Outbound: model plane

    override int encode_hello(SyncPeer peer)
    {
        import urt.conv : format_uint;
        import manager : get_module;
        import manager.system : node_id;
        import manager.sync.discovery : SyncDiscoveryModule, PeerRole, role_name;

        begin_frame("hello");
        _buf.append(",\"ver\":", model_protocol_version);

        char[16] id = void;
        format_uint(node_id(), id[], 16, 16, '0');
        _buf.append(",\"node\":\"", id[], '\"');

        import urt.encoding : hex_encode;
        char[32] nonce = void;
        hex_encode(peer.local_nonce(), nonce[]);
        _buf.append(",\"nonce\":\"", nonce[], '\"');
        PeerRole role = peer.claim ? PeerRole.authority : get_module!SyncDiscoveryModule.local_role;
        if (role != PeerRole.none)
            _buf.append(",\"role\":\"", role_name(role), '\"');
        _buf ~= ",\"caps\":[";
        bool first = true;
        foreach (bit; 0 .. 8)
        {
            if (!(local_sync_caps & (1 << bit)))
                continue;
            if (!first)
                _buf ~= ',';
            first = false;
            _buf.append('\"', enum_key_from_value!SyncCaps(cast(SyncCaps)(1 << bit)), '\"');
        }
        _buf ~= "],\"encoders\":[\"json\"]";
        _buf.append(",\"max_frame\":", peer.local_max_message, ",\"segment\":", peer.local_segment);
        return send_frame(peer);
    }

    override void encode_identity(SyncPeer peer)
    {
        import manager : get_module;
        import manager.system : hostname;
        import manager.sync.discovery : SyncDiscoveryModule;

        begin_frame("identity");
        _buf ~= ",\"host\":";
        write_str(hostname[]);
        auto disco = get_module!SyncDiscoveryModule;
        if (disco.local_cluster.length)
        {
            _buf ~= ",\"cluster\":";
            write_str(disco.local_cluster[]);
        }
        send_frame(peer);
    }

    override void encode_claim(SyncPeer peer, uint seq, const(char)[] cluster, uint priority, const(char)[] auth, const(char)[] key)
    {
        begin_frame("claim");
        _buf.append(",\"seq\":", seq);
        _buf ~= ",\"cluster\":";
        write_str(cluster);
        _buf.append(",\"priority\":", priority);
        if (auth.length)
        {
            _buf ~= ",\"auth\":";
            write_str(auth);
        }
        if (key.length)
        {
            _buf ~= ",\"key\":";
            write_str(key);
        }
        send_frame(peer);
    }

    override void encode_model_sub(SyncPeer peer, uint seq, const(char[])[] patterns, bool once)
    {
        begin_frame("sub");
        _buf.append(",\"seq\":", seq);
        _buf ~= ",\"patterns\":[";
        foreach (i, p; patterns)
        {
            if (i)
                _buf ~= ',';
            write_str(p);
        }
        _buf ~= ']';
        if (once)
            _buf ~= ",\"once\":true";
        send_frame(peer);
    }

    override void encode_model_set(SyncPeer peer, uint seq, SyncHandle h, ref const Variant value)
    {
        begin_frame("set");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"h\":", h);
        _buf ~= ",\"value\":";
        write_variant(value);
        send_frame(peer);
    }

    override void encode_type_format(SyncPeer peer, uint ft, ref const DataFormat fmt)
    {
        import manager.sample : enum_info_name;

        begin_frame("type");
        _buf.append(",\"ft\":", ft);
        _buf ~= ",\"format\":{\"type\":";
        write_str(wire_type_name(fmt));
        _buf.append(",\"series\":\"", enum_key_from_value!SeriesKind(fmt.kind), '\"');
        if (fmt.count != 1)
            _buf.append(",\"count\":", fmt.count);
        if (fmt.rate)
            _buf.append(",\"rate\":", fmt.rate);
        if (fmt.desc == DataFormat.Desc.quantity)
            _buf.append(",\"unit\":\"", fmt.unit, '\"');
        else if (fmt.desc == DataFormat.Desc.enum_)
        {
            _buf ~= ",\"enum\":";
            write_str(enum_info_name(fmt.enum_info));
        }
        if (fmt.constraint && fmt.is_scalar)
        {
            ref const Constraint c = *fmt.constraint;
            if (c.has & Constraint.Has.min)
            {
                _buf ~= ",\"min\":";
                append_scalar(c.min, fmt.type);
            }
            if (c.has & Constraint.Has.max)
            {
                _buf ~= ",\"max\":";
                append_scalar(c.max, fmt.type);
            }
            if (c.has & Constraint.Has.step)
            {
                _buf ~= ",\"step\":";
                append_scalar(c.step, fmt.type);
            }
        }
        _buf ~= '}';
        send_frame(peer);
    }

    override void encode_type_enum(SyncPeer peer, const(char)[] name, const(VoidEnumInfo)* info)
    {
        begin_frame("type");
        _buf ~= ",\"name\":";
        write_str(name);
        _buf ~= ",\"members\":{";
        foreach (i; 0 .. info.count)
        {
            const(char)[] key = info.key_by_decl_index(i);
            if (i)
                _buf ~= ',';
            write_str(key);
            _buf.append(':', info.value_for(key).asLong);
        }
        _buf ~= '}';
        send_frame(peer);
    }

    override void encode_add(SyncPeer peer, SyncHandle h, const(char)[] path, const(char)[] node_class, const(char)[] templates, uint ft, Element* e, ulong peer_id)
    {
        import manager.element : Access;

        begin_frame("add");
        _buf.append(",\"h\":", h);
        _buf ~= ",\"path\":";
        write_str(path);
        _buf.append(",\"class\":\"", node_class, '\"');
        if (peer_id)
        {
            import urt.conv : format_uint;
            char[16] id = void;
            format_uint(peer_id, id[], 16, 16, '0');
            _buf.append(",\"peer\":\"", id[], '\"');
        }
        if (e)
        {
            _buf.append(",\"ft\":", ft);
            if (e.access != Access.read)
                _buf.append(",\"access\":\"", enum_key_from_value!Access(e.access), '\"');
        }
        if (templates.length)
        {
            _buf ~= ",\"tmpl\":";
            write_str(templates);
        }
        send_frame(peer);
    }

    override uint encode_samples(SyncPeer peer, SyncHandle h, ulong lost, uint available, scope SampleAt sample, uint seq)
    {
        open_samples(h, lost, seq);
        _buf ~= ",\"s\":[";
        size_t limit = peer.send_limit;
        uint count;
        while (count < available)
        {
            size_t mark = _buf.length;
            ulong t_ms;
            Variant v;
            sample(count, t_ms, v);
            if (count)
                _buf ~= ',';
            _buf.append('[', t_ms, ',');
            write_variant(v);
            _buf ~= ']';
            // the frame closes with "]}"
            if (count && _buf.length + 2 > limit)
            {
                _buf.resize(mark);
                break;
            }
            ++count;
        }
        _buf ~= ']';
        if (count == 1 && _buf.length + 1 > peer.max_message(true))
        {
            warn_unsendable(peer, h);
            open_samples(h, lost + 1, seq);
            _buf ~= ",\"s\":[]";
        }
        return send_frame(peer, seq ? TxQueue.control : TxQueue.val, true) < 0 ? 0 : count;
    }

    override void encode_res(SyncPeer peer, uint seq)
    {
        begin_frame("res");
        _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    override void encode_res(SyncPeer peer, uint seq, ref const Variant value)
    {
        begin_frame("res");
        _buf.append(",\"seq\":", seq);
        _buf ~= ",\"value\":";
        write_variant(value);
        send_frame(peer);
    }

    override void encode_err(SyncPeer peer, uint seq, const(char)[] code, const(char)[] text)
    {
        begin_frame("err");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"code\":\"", code, '\"');
        _buf ~= ",\"text\":";
        write_str(text);
        send_frame(peer);
    }

    // Inbound

    override void decode_and_dispatch(SyncPeer peer, const(ubyte)[] frame)
    {
        Variant parsed = parse_json(cast(char[])cast(const(char)[])frame);
        if (!parsed.isArray)
            return dispatch_message(peer, parsed);
        for (size_t i = 0; i < parsed.length(); ++i)
            dispatch_message(peer, parsed[i]);
    }

    void dispatch_message(SyncPeer peer, ref Variant json)
    {
        if (!json.isObject)
        {
            log.warning("frame is not a JSON object");
            return;
        }

        JsonFrameReader reader = JsonFrameReader(&json);
        const(char)[] kind_str = reader.require_str("kind");
        if (reader.failed || kind_str.length == 0)
        {
            log.warning("frame missing 'kind' field");
            return;
        }

        switch (kind_str)
        {
            case "add_name":
            {
                SyncHandle h = reader.require_handle("h");
                const(char)[] name = reader.require_str("name");
                const(char)[] type = reader.require_str("type");
                if (!reader.failed)
                    sync.inbound_add_name(peer, h, name, type);
                break;
            }

            case "bind":
            {
                CID target = peer.cid_of(reader.require_handle("target"));
                const(char)[] type = reader.require_str("type");
                uint seq = reader.optional_uint("seq");
                Variant* pv = json.getMember("props");
                if (pv && !pv.isObject)
                    reader.bad("props");
                if (reader.failed)
                    break;
                sync.inbound_bind(peer, target, type, seq);
                dispatch_props(peer, target, json);
                break;
            }

            case "unbind":
            {
                CID target = peer.cid_of(reader.require_handle("target"));
                uint seq = reader.optional_uint("seq");
                if (!reader.failed)
                    sync.inbound_unbind(peer, target, seq);
                break;
            }

            case "create":
            {
                const(char)[] type = reader.require_str("type");
                uint seq = reader.optional_uint("seq");

                Array!NamedArgument props;
                Variant* pv = json.getMember("props");
                if (pv && !pv.isObject)
                    reader.bad("props");
                else if (pv)
                {
                    foreach (k, ref v; *pv)
                    {
                        if (k[] == "name" && !v.isString)
                        {
                            reader.bad("props");
                            break;
                        }
                        props ~= NamedArgument(k, v);
                    }
                }

                if (!reader.failed)
                    sync.inbound_create(peer, type, props[], seq);
                break;
            }

            case "destroy":
            {
                CID target = peer.cid_of(reader.require_handle("target"));
                uint seq = reader.optional_uint("seq");
                if (!reader.failed)
                    sync.inbound_destroy(peer, target, seq);
                break;
            }

            case "state":
            {
                const(char)[] sig_str = reader.require_str("signal");
                CID target = peer.cid_of(reader.require_handle("target"));
                if (reader.failed)
                    break;
                const(StateSignal)* sig = enum_from_key!StateSignal(sig_str);
                if (!sig || *sig > StateSignal.offline)
                {
                    log.warning("bad state signal: ", sig_str);
                    break;
                }
                sync.inbound_state(peer, target, *sig);
                break;
            }

            case "set":
            {
                uint seq = reader.optional_uint("seq");
                Variant* val = json.getMember("value");
                if (json.getMember("prop"))
                {
                    // legacy object-mirror property set
                    CID target = peer.cid_of(reader.require_handle("target"));
                    const(char)[] prop = reader.require_str("prop");
                    if (!val)
                        reader.bad("value");
                    if (!reader.failed)
                        sync.inbound_set(peer, target, prop, *val, seq);
                    break;
                }
                SyncHandle h = reader.optional_handle("h");
                const(char)[] path = reader.optional_str("path");
                bool reset = reader.optional_bool("reset");
                if (!reader.failed)
                    sync.inbound_model_set(peer, seq, h, path, val, reset);
                break;
            }

            case "reset":
            {
                CID target = peer.cid_of(reader.require_handle("target"));
                const(char)[] prop = reader.require_str("prop");
                uint seq = reader.optional_uint("seq");
                if (!reader.failed)
                    sync.inbound_reset(peer, target, prop, seq);
                break;
            }

            case "cmd":
            {
                uint seq = reader.require_uint("seq");
                const(char)[] text = reader.require_str("text");
                if (!reader.failed)
                    sync.inbound_cmd(peer, seq, text);
                break;
            }

            case "result":
            {
                uint seq = reader.require_uint("seq");
                Variant* val = json.getMember("value");
                const(char)[] text = reader.optional_str("text");
                Variant empty;
                if (!reader.failed)
                    sync.inbound_result(peer, seq, val ? *val : empty, text);
                break;
            }

            case "suggest":
            {
                uint seq = reader.require_uint("seq");
                const(char)[] text = reader.optional_str("text");
                if (!reader.failed)
                    sync.inbound_suggest(peer, seq, text);
                break;
            }

            case "console":
            {
                uint seq = reader.require_uint("seq");
                const(char)[] event_text = reader.require_str("event");
                const(SyncConsoleEvent)* event_value = enum_from_key!SyncConsoleEvent(event_text);
                if (!event_value)
                    reader.bad("event");
                if (reader.failed)
                    break;

                SyncConsoleEvent event = *event_value;
                const(char)[] data;
                SyncConsoleTerminal terminal;
                final switch (event)
                {
                    case SyncConsoleEvent.open:
                    case SyncConsoleEvent.terminal:
                        uint width = reader.require_uint("width");
                        uint height = reader.require_uint("height");
                        uint features = reader.require_uint("features");
                        const(char)[] terminal_type = reader.optional_str("terminal");
                        if (width > ushort.max || height > ushort.max || features > ushort.max)
                            reader.bad("terminal state");
                        terminal = SyncConsoleTerminal(cast(ushort)width, cast(ushort)height, cast(ClientFeatures)features, terminal_type);
                        break;
                    case SyncConsoleEvent.input:
                    case SyncConsoleEvent.output:
                        data = reader.require_str("data");
                        break;
                    case SyncConsoleEvent.close:
                    case SyncConsoleEvent.closed:
                        break;
                }
                if (!reader.failed)
                    sync.inbound_console(peer, seq, event, data, terminal);
                break;
            }

            case "error":
            {
                uint seq = reader.require_uint("seq");
                const(char)[] text = reader.optional_str("text");
                if (!reader.failed)
                    sync.inbound_error(peer, seq, text);
                break;
            }

            case "sub":
            {
                Variant* pats = json.getMember("patterns");
                if (pats)
                {
                    if (!pats.isArray)
                    {
                        reader.bad("patterns");
                        break;
                    }
                    Array!(const(char)[]) patterns;
                    for (size_t i = 0; i < pats.length(); ++i)
                    {
                        if (!(*pats)[i].isString)
                        {
                            reader.bad("patterns");
                            break;
                        }
                        patterns ~= (*pats)[i].asString();
                    }
                    uint seq = reader.require_uint("seq");
                    bool once = reader.optional_bool("once");
                    ulong from = reader.optional_ulong("from");
                    ulong to = reader.optional_ulong("to");
                    uint points = reader.optional_uint("points");
                    if (!reader.failed)
                        sync.inbound_model_sub(peer, seq, patterns[], once, from, to, points);
                    break;
                }
                const(char)[] pattern = reader.require_str("pattern");
                if (!reader.failed)
                    sync.inbound_sub(peer, pattern.make_string());
                break;
            }

            case "hello":
            {
                ubyte caps;
                Variant* cv = json.getMember("caps");
                if (cv && !cv.isArray)
                    reader.bad("caps");
                else if (cv)
                {
                    for (size_t i = 0; i < cv.length(); ++i)
                    {
                        if (!(*cv)[i].isString)
                        {
                            reader.bad("caps");
                            break;
                        }
                        const(SyncCaps)* c = enum_from_key!SyncCaps((*cv)[i].asString());
                        if (c)
                            caps |= *c;
                    }
                }
                uint max_message = reader.optional_uint("max_frame");
                uint segment = reader.optional_uint("segment");

                import urt.conv : parse_uint;
                import urt.encoding : hex_decode;
                import manager.sync.discovery : PeerRole, role_from_name;
                ulong nid = 0;
                if (const(char)[] node = reader.optional_str("node"))
                    nid = parse_uint(node, null, 16);
                PeerRole role;
                if (const(char)[] role_str = reader.optional_str("role"))
                    role_from_name(role_str, role);
                ubyte[16] nonce_buf = void;
                const(ubyte)[] nonce;
                if (const(char)[] nonce_str = reader.optional_str("nonce"))
                {
                    if (hex_decode(nonce_str, nonce_buf[]) == 16)
                        nonce = nonce_buf[];
                }
                if (!reader.failed)
                    sync.inbound_hello(peer, caps, max_message, nid, role, nonce, segment);
                break;
            }

            case "identity":
                if (!reader.failed)
                    sync.inbound_identity(peer, reader.optional_str("host"), reader.optional_str("cluster"));
                break;

            case "claim":
            {
                uint seq = reader.require_uint("seq");
                const(char)[] cluster = reader.optional_str("cluster");
                uint priority = reader.optional_uint("priority");
                const(char)[] auth = reader.optional_str("auth");
                const(char)[] key = reader.optional_str("key");
                if (!reader.failed)
                    sync.inbound_claim(peer, seq, cluster, priority, auth, key);
                break;
            }

            case "type":
            {
                Variant* fmt = json.getMember("format");
                if (fmt)
                {
                    if (!fmt.isObject)
                    {
                        reader.bad("format");
                        break;
                    }
                    reader.object = fmt;
                    WireFormat wf;
                    wf.type = reader.require_str("type");
                    wf.series = reader.optional_str("series");
                    uint count = reader.optional_uint("count", 1);
                    if (count > ubyte.max)
                        reader.bad("count");
                    wf.count = cast(ubyte)count;
                    wf.rate = reader.optional_uint("rate");
                    wf.unit = reader.optional_str("unit");
                    wf.enum_name = reader.optional_str("enum");
                    if (Variant* mn = fmt.getMember("min"))
                        wf.min = *mn;
                    if (Variant* mx = fmt.getMember("max"))
                        wf.max = *mx;
                    if (Variant* st = fmt.getMember("step"))
                        wf.step = *st;
                    reader.object = &json;
                    uint ft = reader.require_uint("ft");
                    if (!reader.failed)
                        sync.inbound_type_format(peer, ft, wf);
                    break;
                }
                const(char)[] name = reader.require_str("name");
                Variant* members = json.getMember("members");
                if (members)
                {
                    if (!members.isObject)
                        reader.bad("members");
                    else
                        foreach (k, ref v; *members)
                        {
                            if (!v.isLong)
                            {
                                reader.bad("members");
                                break;
                            }
                        }
                }
                Variant empty;
                if (!reader.failed)
                    sync.inbound_type_enum(peer, name, members ? *members : empty);
                break;
            }

            case "add":
            {
                SyncHandle h = reader.require_handle("h");
                const(char)[] path = reader.require_str("path");
                const(char)[] cls = reader.require_str("class");
                uint ft = reader.optional_uint("ft", uint.max);
                const(char)[] access = reader.optional_str("access");
                const(char)[] templates = reader.optional_str("tmpl");
                ulong peer_id;
                if (const(char)[] owner = reader.optional_str("peer"))
                {
                    if (!parse_peer_id(owner, peer_id))
                        reader.bad("peer");
                }
                if (!reader.failed)
                    sync.inbound_model_add(peer, h, path, cls, templates, ft, access, peer_id);
                break;
            }

            case "val":
            {
                SyncHandle h = reader.require_handle("h");
                Variant* smp = json.getMember("s");
                if (!smp || !smp.isArray)
                    reader.bad("s");
                else for (size_t i = 0; i < smp.length(); ++i)
                {
                    ref Variant pair = (*smp)[i];
                    if (!pair.isArray || pair.length() != 2 || !pair[0].isUlong)
                    {
                        reader.bad("s");
                        break;
                    }
                }
                if (reader.failed)
                    break;
                for (size_t i = 0; i < smp.length(); ++i)
                {
                    ref Variant pair = (*smp)[i];
                    sync.inbound_val(peer, h, pair[1], pair[0].asUlong());
                }
                break;
            }

            case "res":
            {
                uint seq = reader.require_uint("seq");
                if (!reader.failed)
                    sync.inbound_res(peer, seq, json.getMember("value"));
                break;
            }

            case "err":
            {
                uint seq = reader.require_uint("seq");
                const(char)[] code = reader.optional_str("code");
                const(char)[] text = reader.optional_str("text");
                if (!reader.failed)
                    sync.inbound_err(peer, seq, code, text);
                break;
            }

            case "unsub":
            {
                Variant* pats = json.getMember("patterns");
                if (pats)
                {
                    if (!pats.isArray)
                    {
                        reader.bad("patterns");
                        break;
                    }
                    Array!(const(char)[]) patterns;
                    for (size_t i = 0; i < pats.length(); ++i)
                    {
                        if (!(*pats)[i].isString)
                        {
                            reader.bad("patterns");
                            break;
                        }
                        patterns ~= (*pats)[i].asString();
                    }
                    if (!reader.failed)
                        sync.inbound_model_unsub(peer, patterns[]);
                    break;
                }
                const(char)[] pattern = reader.require_str("pattern");
                if (!reader.failed)
                    sync.inbound_unsub(peer, pattern);
                break;
            }

            case "enum_req":
            {
                const(char)[] type = reader.require_str("type");
                uint seq = reader.require_uint("seq");
                if (!reader.failed)
                    sync.inbound_enum_req(peer, type, seq);
                break;
            }

            case "enum":
            {
                const(char)[] type = reader.require_str("type");
                uint seq = reader.optional_uint("seq");
                Variant* members = json.getMember("members");
                Variant empty;
                if (!reader.failed)
                    sync.inbound_enum(peer, type, members ? *members : empty, seq);
                break;
            }

            case "log_sub":
            {
                const(char)[] sev_str = reader.require_str("severity");
                if (reader.failed)
                    break;
                bool off = sev_str == "off";
                Severity sev = Severity.info;
                if (!off)
                {
                    const(Severity)* sv = enum_from_key!Severity(sev_str);
                    if (!sv)
                    {
                        log.warning("unknown log_sub severity: ", sev_str);
                        break;
                    }
                    sev = *sv;
                }
                const(char)[] tag = reader.optional_str("tag");
                if (!reader.failed)
                    sync.inbound_log_sub(peer, sev, off, tag);
                break;
            }

            case "log":
            {
                Variant* msg_v = json.getMember("msg");
                if (!msg_v || !msg_v.isString)
                {
                    log.warning("log missing string 'msg'");
                    break;
                }
                sync.inbound_log(peer, msg_v.asString());
                break;
            }

            case "time_req":
            {
                uint seq = reader.require_uint("seq");
                if (!reader.failed)
                    sync.inbound_time_req(peer, seq);
                break;
            }

            case "time_resp":
            {
                // an incomplete response must never discipline the clock toward zero
                uint seq = reader.require_uint("seq");
                ulong recv = reader.require_ulong("recv");
                ulong xmit = reader.require_ulong("xmit");
                uint ver = reader.require_uint("ver");
                if (!reader.failed)
                    sync.inbound_time_resp(peer, seq, recv, xmit, ver);
                break;
            }

            case "time_push":
            {
                uint ver = reader.require_uint("ver");
                long delta = reader.require_long("delta");
                if (!reader.failed)
                    sync.inbound_time_push(peer, ver, delta);
                break;
            }

            default:
                log.warning("unknown kind: ", kind_str);
                break;
        }
    }

    // For bind: iterate the frame's "props" object (if present) and emit one
    // inbound_set per kv pair. seq=0 - initial props aren't a request, just
    // part of the bind state transfer.
    void dispatch_props(SyncPeer peer, CID target, ref Variant json)
    {
        Variant* pv = json.getMember("props");
        if (!pv || !pv.isObject)
            return;
        foreach (k, ref v; *pv)
            sync.inbound_set(peer, target, k, v, 0);
    }

    // Per-peer per-tick property flush
    //
    // JSON layout: one frame per dirty property (readability > compactness).
    // `props_dirty` bits AND `_props_set` → emit set; bits AND NOT `_props_set`
    // → emit reset (property was un-assigned).

    override void tick_dirty(SyncPeer peer)
    {
        uint gen = peer.begin_burst();
        foreach (obj; peer._bound[])
        {
            if (obj._is_remote)
                continue;

            ushort slot = sync.find_sync_slot(obj, peer);
            if (slot == sync_slot_none)
                continue;

            ref ss = sync_state(slot);
            ulong dirty = ss.props_dirty;
            if (!dirty)
                continue;

            ulong set_bits = dirty & obj.props_set;

            ulong sent_bits = 0;
            auto props = obj.properties();
            foreach (i, p; props)
            {
                ulong mask = ulong(1) << i;
                if (!(dirty & mask))
                    continue;

                if (set_bits & mask)
                    encode_set(peer, obj, i, 0);
                else
                {
                    debug assert_reset_matches_init(obj, *p);
                    encode_reset(peer, obj.id, p.name[], 0);
                }

                if (!peer.send_ok(gen))
                {
                    ss.props_dirty &= ~sent_bits;
                    return;
                }
                sent_bits |= mask;
            }
            ss.props_dirty &= ~sent_bits;
        }
    }

private:
    Array!char _buf;

    void encode_text_command(SyncPeer peer, const(char)[] verb, uint seq, const(char)[] text)
    {
        begin_frame(verb);
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"text\":");
        write_str(text);
        send_frame(peer);
    }

    void begin_property_frame(SyncPeer peer, const(char)[] verb, CID target, const(char)[] prop_name)
    {
        begin_frame(verb);
        _buf.append(",\"target\":", peer.handle_of(target));
        _buf.append(",\"prop\":");
        write_str(prop_name);
    }

    void finish_property_frame(SyncPeer peer, uint seq)
    {
        if (seq)
            _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    void begin_frame(const(char)[] kind)
    {
        _buf.clear();
        _buf.append("{\"kind\":\"", kind, "\"");
    }

    void open_samples(SyncHandle h, ulong lost, uint seq)
    {
        begin_frame("val");
        if (seq)
            _buf.append(",\"seq\":", seq);
        _buf.append(",\"h\":", h);
        if (lost)
            _buf.append(",\"lost\":", lost);
    }

    int send_frame(SyncPeer peer, TxQueue queue = TxQueue.control, bool bundled = false)
    {
        _buf ~= '}';
        const(ubyte)[] frame = cast(const(ubyte)[])_buf[];
        immutable bool direct = queue == TxQueue.control && !bundled;
        int r = direct ? peer.transmit_frame(frame, true, queue) : peer.bundle(frame, queue);
        if (r < 0 && direct)
        {
            // event-driven encodes (state/cmd/result/error/sub/...) have no retry path!!
            // a drop here means the peer permanently misses this event; a refused bundle stays with its producer.
            const preview = _buf.length < 200 ? _buf.length : 200;
            log.warning("dropped frame to peer (", _buf.length, "B): ", cast(const(char)[])_buf[0 .. preview], _buf.length > 200 ? "..." : "");
        }
        return r;
    }

    void write_str(const(char)[] s)
    {
        const v = Variant(s);
        if (!append_json(_buf, v, "\"\""))
            log.warning("string has no JSON encoding (", s.length, "B); sent empty");
    }

    static bool parse_peer_id(const(char)[] text, out ulong peer_id) pure
    {
        import urt.conv : parse_uint;
        size_t taken;
        peer_id = parse_uint(text, &taken, 16);
        return peer_id && taken == text.length;
    }

    void write_variant(ref const Variant v)
    {
        if (!append_json(_buf, v))
            log.warning("value has no JSON encoding; sent null");
    }

    // constraint scalars are typed by their format; read stride bytes like compare_scalar does
    void append_scalar(ref const Scalar s, ValueType t)
    {
        final switch (t) with (ValueType)
        {
            case bool_: _buf ~= *cast(const(bool)*)s.raw.ptr ? "true" : "false";    break;
            case u8:    _buf.append(*cast(const(ubyte)*)s.raw.ptr);                 break;
            case s8:    _buf.append(*cast(const(byte)*)s.raw.ptr);                  break;
            case u16:   _buf.append(*cast(const(ushort)*)s.raw.ptr);                break;
            case s16:   _buf.append(*cast(const(short)*)s.raw.ptr);                 break;
            case u32:   _buf.append(*cast(const(uint)*)s.raw.ptr);                  break;
            case s32:   _buf.append(*cast(const(int)*)s.raw.ptr);                   break;
            case u64:   _buf.append(*cast(const(ulong)*)s.raw.ptr);                 break;
            case s64:   _buf.append(*cast(const(long)*)s.raw.ptr);                  break;
            case f32:   _buf.append(*cast(const(float)*)s.raw.ptr);                 break;
            case f64:   _buf.append(*cast(const(double)*)s.raw.ptr);                break;
            case char_:
            case user:  assert(false, "constraint on non-numeric type");
        }
    }

    // Emit all SET props, including read-only ones - proxies can't
    // recompute derived state, so they need the authoritative value
    // delivered.
    void write_obj_props(BaseObject obj)
    {
        auto props = obj.properties();
        ulong set_bits = obj.props_set;
        bool any = false;
        foreach (i, p; props)
        {
            ulong mask = ulong(1) << i;
            if (!(set_bits & mask))
                continue;
            if (!p.get)
                continue;
            if (p.name[] == "type")
                continue;   // already in outer frame

            if (!any)
            {
                _buf.append(",\"props\":{");
                any = true;
            }
            else
                _buf ~= ',';
            write_str(p.name[]);
            _buf ~= ':';
            Variant val = p.get(obj, *p);
            write_variant(val);
        }
        if (any)
            _buf ~= '}';
    }
}

private struct JsonFrameReader
{
nothrow @nogc:

    Variant* object;
    bool failed;

    void bad(const(char)[] name)
    {
        if (!failed)
            JsonEncoder.log.warning("bad or missing field '", name, "'");
        failed = true;
    }

    uint require_uint(const(char)[] name)
    {
        Variant* m = object.getMember(name);
        if (m && m.isUint)
            return m.asUint();
        bad(name);
        return 0;
    }

    uint optional_uint(const(char)[] name, uint def = 0)
    {
        Variant* m = object.getMember(name);
        if (!m)
            return def;
        if (m.isUint)
            return m.asUint();
        bad(name);
        return def;
    }

    ulong require_ulong(const(char)[] name)
    {
        Variant* m = object.getMember(name);
        if (m && m.isUlong)
            return m.asUlong();
        bad(name);
        return 0;
    }

    ulong optional_ulong(const(char)[] name, ulong def = 0)
    {
        Variant* m = object.getMember(name);
        if (!m)
            return def;
        if (m.isUlong)
            return m.asUlong();
        bad(name);
        return def;
    }

    long require_long(const(char)[] name)
    {
        Variant* m = object.getMember(name);
        if (m && m.isLong)
            return m.asLong();
        bad(name);
        return 0;
    }

    const(char)[] require_str(const(char)[] name)
    {
        Variant* m = object.getMember(name);
        if (m && m.isString)
            return m.asString();
        bad(name);
        return null;
    }

    const(char)[] optional_str(const(char)[] name)
    {
        Variant* m = object.getMember(name);
        if (!m || m.isNull)
            return null;
        if (m.isString)
            return m.asString();
        bad(name);
        return null;
    }

    bool optional_bool(const(char)[] name)
    {
        Variant* m = object.getMember(name);
        if (!m)
            return false;
        if (m.isBool)
            return m.isTrue;
        bad(name);
        return false;
    }

    SyncHandle require_handle(const(char)[] name)
        => cast(SyncHandle)require_ulong(name);

    SyncHandle optional_handle(const(char)[] name)
        => cast(SyncHandle)optional_ulong(name, SyncPeer.invalid_handle);
}


unittest
{
    // pins the range-checked predicate semantics the decoder gates every as*() behind
    char[64] buf = void;
    const(char)[] src = `{"a":-1,"b":1.5,"c":1e100,"d":7,"e":4294967296}`;
    buf[0 .. src.length] = src[];
    Variant v = parse_json(buf[0 .. src.length]);
    assert(v.isObject);

    Variant* a = v.getMember("a");
    assert(a.isNumber && !a.isUint && !a.isUlong && a.isLong);

    Variant* b = v.getMember("b");
    assert(b.isNumber && !b.isUint && !b.isUlong && !b.isLong);

    Variant* c = v.getMember("c");
    assert(c.isNumber && !c.isUint && !c.isUlong && !c.isLong);

    Variant* d = v.getMember("d");
    assert(d.isUint && d.isUlong && d.isLong);

    Variant* e = v.getMember("e");
    assert(!e.isUint && e.isUlong && e.isLong);

    assert(v.getMember("missing") is null);

    JsonFrameReader reader = JsonFrameReader(&v);
    assert(reader.optional_uint("missing", 1) == 1 && !reader.failed);
    assert(reader.optional_str("missing") is null && !reader.failed);
    assert(reader.require_uint("d") == 7 && !reader.failed);
    assert(reader.optional_uint("a", 1) == 1 && reader.failed);

    ulong peer_id;
    assert(JsonEncoder.parse_peer_id("0123456789abcdef", peer_id));
    assert(peer_id == 0x0123_4567_89AB_CDEF);
    assert(!JsonEncoder.parse_peer_id("", peer_id));
    assert(!JsonEncoder.parse_peer_id("123xyz", peer_id));
    assert(!JsonEncoder.parse_peer_id("0000000000000000", peer_id));
}
