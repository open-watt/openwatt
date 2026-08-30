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
import urt.variant;

import manager.base;
import manager.collection;
import manager.console.session : ClientFeatures;
import manager.element : Element;
import manager.record : Sample;
import manager.series : Constraint, DataFormat, RecordBlock, Scalar, SeriesKind, ValueType;
import manager.sync;
import manager.sync.encoder;
import manager.sync.peer;


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

        begin_frame("set");
        _buf.append(",\"target\":", peer.handle_of(obj));
        _buf.append(",\"prop\":");
        write_str(p.name[]);
        _buf.append(",\"value\":");
        Variant v = p.get(obj, *p);
        write_variant(v);
        if (seq)
            _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    override void encode_set(SyncPeer peer, CID target, const(char)[] prop_name, ref const Variant value, uint seq)
    {
        begin_frame("set");
        _buf.append(",\"target\":", peer.handle_of(target));
        _buf.append(",\"prop\":");
        write_str(prop_name);
        _buf.append(",\"value\":");
        write_variant(value);
        if (seq)
            _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    override void encode_reset(SyncPeer peer, CID target, const(char)[] prop_name, uint seq)
    {
        begin_frame("reset");
        _buf.append(",\"target\":", peer.handle_of(target));
        _buf.append(",\"prop\":");
        write_str(prop_name);
        if (seq)
            _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    // Outbound: commands, errors, enums, subscriptions

    override void encode_cmd(SyncPeer peer, uint seq, const(char)[] text)
    {
        begin_frame("cmd");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"text\":");
        write_str(text);
        send_frame(peer);
    }

    override void encode_result(SyncPeer peer, uint seq, ref const Variant value, const(char)[] out_text)
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
        send_frame(peer);
    }

    override void encode_error(SyncPeer peer, uint seq, const(char)[] text)
    {
        begin_frame("error");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"text\":");
        write_str(text);
        send_frame(peer);
    }

    override void encode_suggest(SyncPeer peer, uint seq, const(char)[] text)
    {
        begin_frame("suggest");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"text\":");
        write_str(text);
        send_frame(peer);
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

    override void encode_console(SyncPeer peer, uint seq, SyncConsoleEvent event, const(char)[] data = null, SyncConsoleTerminal terminal = SyncConsoleTerminal())
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
        send_frame(peer);
    }

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

    override void encode_history_req(SyncPeer peer, const(char)[] path, ulong from_ms, ulong to_ms, uint max_points, uint seq)
    {
        begin_frame("history_req");
        _buf.append(",\"path\":");
        write_str(path);
        _buf.append(",\"from\":", from_ms);
        if (to_ms)
            _buf.append(",\"to\":", to_ms);
        if (max_points)
            _buf.append(",\"max\":", max_points);
        _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    override void encode_history(SyncPeer peer, uint seq, const(char)[] path, const(Sample)[] samples)
    {
        begin_frame("history");
        _buf.append(",\"seq\":", seq);
        _buf.append(",\"path\":");
        write_str(path);
        _buf.append(",\"samples\":[");
        foreach (i, ref s; samples)
        {
            if (i)
                _buf ~= ',';
            _buf.append('[', s.time / 1_000_000, ',');
            const v = Variant(s.value);
            write_variant(v);
            _buf ~= ']';
        }
        _buf ~= ']';
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

    override bool encode_log(SyncPeer peer, const(char)[] line)
    {
        begin_frame("log");
        _buf.append(",\"msg\":");
        write_str(line);
        return send_frame(peer, TxQueue.log) >= 0;
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

    override void encode_hello(SyncPeer peer)
    {
        import urt.conv : format_uint;
        import manager : get_module;
        import manager.system : hostname, node_id;
        import manager.sync.discovery : SyncDiscoveryModule, PeerRole, role_name;

        begin_frame("hello");
        _buf.append(",\"ver\":", model_protocol_version);
        _buf.append(",\"host\":");
        write_str(hostname[]);

        char[16] id = void;
        format_uint(node_id(), id[], 16, 16, '0');
        _buf.append(",\"node\":\"", id[], '\"');

        import urt.encoding : hex_encode;
        char[32] nonce = void;
        hex_encode(peer.local_nonce(), nonce[]);
        _buf.append(",\"nonce\":\"", nonce[], '\"');
        auto disco = get_module!SyncDiscoveryModule;
        if (disco.local_role != PeerRole.none)
            _buf.append(",\"role\":\"", role_name(disco.local_role), '\"');
        if (disco.local_cluster.length)
        {
            _buf ~= ",\"cluster\":";
            write_str(disco.local_cluster[]);
        }
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
        _buf.append(",\"max_frame\":", max_frame_size);
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

    override void encode_add(SyncPeer peer, SyncHandle h, const(char)[] path, const(char)[] node_class, uint ft, Element* e, ulong peer_id, bool include_value = true)
    {
        import urt.time : unix_time_ns;
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
            if (include_value && e.data_format.kind != SeriesKind.point)
            {
                // events retain no value; occurrences replay via `from`
                Variant v = e.value;
                if (!v.isNull)
                {
                    _buf ~= ",\"v\":";
                    write_variant(v);
                    _buf.append(",\"t\":", unix_time_ns(e.last_update) / 1_000_000);
                }
            }
        }
        send_frame(peer);
    }

    override void encode_val(SyncPeer peer, SyncHandle h, Element* e)
    {
        import urt.time : unix_time_ns;

        begin_frame("val");
        _buf.append(",\"h\":", h);
        _buf.append(",\"s\":[[", unix_time_ns(e.last_update) / 1_000_000, ',');
        Variant v = e.value;
        write_variant(v);
        _buf ~= "]]";
        send_frame(peer, TxQueue.val);
    }

    override void encode_val_block(SyncPeer peer, SyncHandle h, ref const RecordBlock blk)
    {
        import urt.time : unix_time_ns;

        begin_frame("val");
        _buf.append(",\"h\":", h);
        if (blk.lost)
            _buf.append(",\"lost\":", blk.lost);
        _buf ~= ",\"s\":[";
        foreach (i; 0 .. blk.count)
        {
            if (i)
                _buf ~= ',';
            _buf.append('[', unix_time_ns(blk.time(i)) / 1_000_000, ',');
            Variant v = blk.box(i);
            write_variant(v);
            _buf ~= ']';
        }
        _buf ~= ']';
        send_frame(peer, TxQueue.val);
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

    override bool decode_and_dispatch(SyncPeer peer, const(ubyte)[] frame)
    {
        Variant json = parse_json(cast(char[])cast(const(char)[])frame);
        if (!json.isObject)
        {
            log.warning("frame is not a JSON object");
            return true;
        }

        // a required field absent or mistyped drops the whole frame; optional fields default only when absent
        bool bad_frame;
        void bad(const(char)[] name)
        {
            if (!bad_frame)
                log.warning("bad or missing field '", name, "'");
            bad_frame = true;
        }
        uint require_uint(ref Variant obj, const(char)[] name)
        {
            Variant* m = obj.getMember(name);
            if (m && m.isUint)
                return m.asUint();
            bad(name);
            return 0;
        }
        uint optional_uint(ref Variant obj, const(char)[] name, uint def = 0)
        {
            Variant* m = obj.getMember(name);
            if (!m)
                return def;
            if (m.isUint)
                return m.asUint();
            bad(name);
            return def;
        }
        ulong require_ulong(ref Variant obj, const(char)[] name)
        {
            Variant* m = obj.getMember(name);
            if (m && m.isUlong)
                return m.asUlong();
            bad(name);
            return 0;
        }
        ulong optional_ulong(ref Variant obj, const(char)[] name, ulong def = 0)
        {
            Variant* m = obj.getMember(name);
            if (!m)
                return def;
            if (m.isUlong)
                return m.asUlong();
            bad(name);
            return def;
        }
        long require_long(ref Variant obj, const(char)[] name)
        {
            Variant* m = obj.getMember(name);
            if (m && m.isLong)
                return m.asLong();
            bad(name);
            return 0;
        }
        const(char)[] require_str(ref Variant obj, const(char)[] name)
        {
            Variant* m = obj.getMember(name);
            if (m && m.isString)
                return m.asString();
            bad(name);
            return null;
        }
        const(char)[] optional_str(ref Variant obj, const(char)[] name)
        {
            Variant* m = obj.getMember(name);
            if (!m || m.isNull)
                return null;
            if (m.isString)
                return m.asString();
            bad(name);
            return null;
        }
        bool optional_bool(ref Variant obj, const(char)[] name)
        {
            Variant* m = obj.getMember(name);
            if (!m)
                return false;
            if (m.isBool)
                return m.isTrue;
            bad(name);
            return false;
        }
        SyncHandle require_handle(ref Variant obj, const(char)[] name)
            => cast(SyncHandle)require_ulong(obj, name);
        SyncHandle optional_handle(ref Variant obj, const(char)[] name)
            => cast(SyncHandle)optional_ulong(obj, name, SyncPeer.invalid_handle);

        const(char)[] kind_str = require_str(json, "kind");
        if (bad_frame || kind_str.length == 0)
        {
            log.warning("frame missing 'kind' field");
            return true;
        }

        switch (kind_str)
        {
            case "add_name":
            {
                SyncHandle h = require_handle(json, "h");
                const(char)[] name = require_str(json, "name");
                const(char)[] type = require_str(json, "type");
                if (!bad_frame)
                    sync.inbound_add_name(peer, h, name, type);
                break;
            }

            case "bind":
            {
                CID target = peer.cid_of(require_handle(json, "target"));
                const(char)[] type = require_str(json, "type");
                uint seq = optional_uint(json, "seq");
                Variant* pv = json.getMember("props");
                if (pv && !pv.isObject)
                    bad("props");
                if (bad_frame)
                    break;
                sync.inbound_bind(peer, target, type, seq);
                dispatch_props(peer, target, json);
                break;
            }

            case "unbind":
            {
                CID target = peer.cid_of(require_handle(json, "target"));
                uint seq = optional_uint(json, "seq");
                if (!bad_frame)
                    sync.inbound_unbind(peer, target, seq);
                break;
            }

            case "create":
            {
                const(char)[] type = require_str(json, "type");
                uint seq = optional_uint(json, "seq");

                Array!NamedArgument props;
                Variant* pv = json.getMember("props");
                if (pv && !pv.isObject)
                    bad("props");
                else if (pv)
                {
                    foreach (k, ref v; *pv)
                    {
                        if (k[] == "name" && !v.isString)
                        {
                            bad("props");
                            break;
                        }
                        props ~= NamedArgument(k, v);
                    }
                }

                if (!bad_frame)
                    sync.inbound_create(peer, type, props[], seq);
                break;
            }

            case "destroy":
            {
                CID target = peer.cid_of(require_handle(json, "target"));
                uint seq = optional_uint(json, "seq");
                if (!bad_frame)
                    sync.inbound_destroy(peer, target, seq);
                break;
            }

            case "state":
            {
                const(char)[] sig_str = require_str(json, "signal");
                CID target = peer.cid_of(require_handle(json, "target"));
                if (bad_frame)
                    break;
                const(StateSignal)* sig = enum_from_key!StateSignal(sig_str);
                if (!sig || *sig == StateSignal.destroyed)
                {
                    log.warning("bad state signal: ", sig_str);
                    break;
                }
                sync.inbound_state(peer, target, *sig);
                break;
            }

            case "set":
            {
                uint seq = optional_uint(json, "seq");
                Variant* val = json.getMember("value");
                if (json.getMember("prop"))
                {
                    // legacy object-mirror property set
                    CID target = peer.cid_of(require_handle(json, "target"));
                    const(char)[] prop = require_str(json, "prop");
                    if (!val)
                        bad("value");
                    if (!bad_frame)
                        sync.inbound_set(peer, target, prop, *val, seq);
                    break;
                }
                SyncHandle h = optional_handle(json, "h");
                const(char)[] path = optional_str(json, "path");
                bool reset = optional_bool(json, "reset");
                if (!bad_frame)
                    sync.inbound_model_set(peer, seq, h, path, val, reset);
                break;
            }

            case "reset":
            {
                CID target = peer.cid_of(require_handle(json, "target"));
                const(char)[] prop = require_str(json, "prop");
                uint seq = optional_uint(json, "seq");
                if (!bad_frame)
                    sync.inbound_reset(peer, target, prop, seq);
                break;
            }

            case "cmd":
            {
                uint seq = require_uint(json, "seq");
                const(char)[] text = require_str(json, "text");
                if (!bad_frame)
                    sync.inbound_cmd(peer, seq, text);
                break;
            }

            case "result":
            {
                uint seq = require_uint(json, "seq");
                Variant* val = json.getMember("value");
                const(char)[] text = optional_str(json, "text");
                Variant empty;
                if (!bad_frame)
                    sync.inbound_result(peer, seq, val ? *val : empty, text);
                break;
            }

            case "suggest":
            {
                uint seq = require_uint(json, "seq");
                const(char)[] text = optional_str(json, "text");
                if (!bad_frame)
                    sync.inbound_suggest(peer, seq, text);
                break;
            }

            case "console":
            {
                uint seq = require_uint(json, "seq");
                const(char)[] event_text = require_str(json, "event");
                const(SyncConsoleEvent)* event_value = enum_from_key!SyncConsoleEvent(event_text);
                if (!event_value)
                    bad("event");
                if (bad_frame)
                    break;

                SyncConsoleEvent event = *event_value;
                const(char)[] data;
                SyncConsoleTerminal terminal;
                final switch (event)
                {
                    case SyncConsoleEvent.open:
                    case SyncConsoleEvent.terminal:
                        uint width = require_uint(json, "width");
                        uint height = require_uint(json, "height");
                        uint features = require_uint(json, "features");
                        const(char)[] terminal_type = optional_str(json, "terminal");
                        if (width > ushort.max || height > ushort.max || features > ushort.max)
                            bad("terminal state");
                        terminal = SyncConsoleTerminal(cast(ushort)width, cast(ushort)height, cast(ClientFeatures)features, terminal_type);
                        break;
                    case SyncConsoleEvent.input:
                    case SyncConsoleEvent.output:
                        data = require_str(json, "data");
                        break;
                    case SyncConsoleEvent.close:
                    case SyncConsoleEvent.closed:
                        break;
                }
                if (!bad_frame)
                    sync.inbound_console(peer, seq, event, data, terminal);
                break;
            }

            case "error":
            {
                uint seq = require_uint(json, "seq");
                const(char)[] text = optional_str(json, "text");
                if (!bad_frame)
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
                        bad("patterns");
                        break;
                    }
                    Array!(const(char)[]) patterns;
                    for (size_t i = 0; i < pats.length(); ++i)
                    {
                        if (!(*pats)[i].isString)
                        {
                            bad("patterns");
                            break;
                        }
                        patterns ~= (*pats)[i].asString();
                    }
                    uint seq = require_uint(json, "seq");
                    bool once = optional_bool(json, "once");
                    ulong from = optional_ulong(json, "from");
                    ulong to = optional_ulong(json, "to");
                    if (!bad_frame)
                        sync.inbound_model_sub(peer, seq, patterns[], once, from, to);
                    break;
                }
                const(char)[] pattern = require_str(json, "pattern");
                if (!bad_frame)
                    sync.inbound_sub(peer, pattern.make_string());
                break;
            }

            case "hello":
            {
                ubyte caps;
                Variant* cv = json.getMember("caps");
                if (cv && !cv.isArray)
                    bad("caps");
                else if (cv)
                {
                    for (size_t i = 0; i < cv.length(); ++i)
                    {
                        if (!(*cv)[i].isString)
                        {
                            bad("caps");
                            break;
                        }
                        const(SyncCaps)* c = enum_from_key!SyncCaps((*cv)[i].asString());
                        if (c)
                            caps |= *c;
                    }
                }
                uint max_frame = optional_uint(json, "max_frame");

                import urt.conv : parse_uint;
                import urt.encoding : hex_decode;
                import manager.sync.discovery : PeerRole, role_from_name;
                ulong nid = 0;
                if (const(char)[] node = optional_str(json, "node"))
                    nid = parse_uint(node, null, 16);
                PeerRole role;
                if (const(char)[] role_str = optional_str(json, "role"))
                    role_from_name(role_str, role);
                const(char)[] cluster = optional_str(json, "cluster");
                ubyte[16] nonce_buf = void;
                const(ubyte)[] nonce;
                if (const(char)[] nonce_str = optional_str(json, "nonce"))
                {
                    if (hex_decode(nonce_str, nonce_buf[]) == 16)
                        nonce = nonce_buf[];
                }
                uint ver = optional_uint(json, "ver");
                const(char)[] host = optional_str(json, "host");

                if (!bad_frame)
                    sync.inbound_hello(peer, ver, host, caps, max_frame, nid, role, cluster, nonce);
                break;
            }

            case "claim":
            {
                uint seq = require_uint(json, "seq");
                const(char)[] cluster = optional_str(json, "cluster");
                uint priority = optional_uint(json, "priority");
                const(char)[] auth = optional_str(json, "auth");
                const(char)[] key = optional_str(json, "key");
                if (!bad_frame)
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
                        bad("format");
                        break;
                    }
                    WireFormat wf;
                    wf.type = require_str(*fmt, "type");
                    wf.series = optional_str(*fmt, "series");
                    uint count = optional_uint(*fmt, "count", 1);
                    if (count > ubyte.max)
                        bad("count");
                    wf.count = cast(ubyte)count;
                    wf.rate = optional_uint(*fmt, "rate");
                    wf.unit = optional_str(*fmt, "unit");
                    wf.enum_name = optional_str(*fmt, "enum");
                    if (Variant* mn = fmt.getMember("min"))
                        wf.min = *mn;
                    if (Variant* mx = fmt.getMember("max"))
                        wf.max = *mx;
                    if (Variant* st = fmt.getMember("step"))
                        wf.step = *st;
                    uint ft = require_uint(json, "ft");
                    if (!bad_frame)
                        sync.inbound_type_format(peer, ft, wf);
                    break;
                }
                const(char)[] name = require_str(json, "name");
                Variant* members = json.getMember("members");
                if (members)
                {
                    if (!members.isObject)
                        bad("members");
                    else
                        foreach (k, ref v; *members)
                        {
                            if (!v.isLong)
                            {
                                bad("members");
                                break;
                            }
                        }
                }
                Variant empty;
                if (!bad_frame)
                    sync.inbound_type_enum(peer, name, members ? *members : empty);
                break;
            }

            case "add":
            {
                SyncHandle h = require_handle(json, "h");
                const(char)[] path = require_str(json, "path");
                const(char)[] cls = require_str(json, "class");
                uint ft = optional_uint(json, "ft", uint.max);
                const(char)[] access = optional_str(json, "access");
                ulong t = optional_ulong(json, "t");
                ulong peer_id;
                if (const(char)[] owner = optional_str(json, "peer"))
                {
                    if (!parse_peer_id(owner, peer_id))
                        bad("peer");
                }
                if (!bad_frame)
                    sync.inbound_model_add(peer, h, path, cls, ft, access, json.getMember("v"), t, peer_id);
                break;
            }

            case "val":
            {
                SyncHandle h = require_handle(json, "h");
                Variant* smp = json.getMember("s");
                if (!smp || !smp.isArray)
                    bad("s");
                else for (size_t i = 0; i < smp.length(); ++i)
                {
                    ref Variant pair = (*smp)[i];
                    if (!pair.isArray || pair.length() != 2 || !pair[0].isUlong)
                    {
                        bad("s");
                        break;
                    }
                }
                if (bad_frame)
                    break;   // a malformed val is consumed whole; false is reserved for the add-in-flight race
                for (size_t i = 0; i < smp.length(); ++i)
                {
                    ref Variant pair = (*smp)[i];
                    if (!sync.inbound_val(peer, h, pair[1], pair[0].asUlong()))
                        return false;
                }
                break;
            }

            case "res":
            {
                uint seq = require_uint(json, "seq");
                if (!bad_frame)
                    sync.inbound_res(peer, seq, json.getMember("value"));
                break;
            }

            case "err":
            {
                uint seq = require_uint(json, "seq");
                const(char)[] code = optional_str(json, "code");
                const(char)[] text = optional_str(json, "text");
                if (!bad_frame)
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
                        bad("patterns");
                        break;
                    }
                    Array!(const(char)[]) patterns;
                    for (size_t i = 0; i < pats.length(); ++i)
                    {
                        if (!(*pats)[i].isString)
                        {
                            bad("patterns");
                            break;
                        }
                        patterns ~= (*pats)[i].asString();
                    }
                    if (!bad_frame)
                        sync.inbound_model_unsub(peer, patterns[]);
                    break;
                }
                const(char)[] pattern = require_str(json, "pattern");
                if (!bad_frame)
                    sync.inbound_unsub(peer, pattern);
                break;
            }

            case "enum_req":
            {
                const(char)[] type = require_str(json, "type");
                uint seq = require_uint(json, "seq");
                if (!bad_frame)
                    sync.inbound_enum_req(peer, type, seq);
                break;
            }

            case "history_req":
            {
                const(char)[] path = require_str(json, "path");
                uint seq = require_uint(json, "seq");
                ulong from = optional_ulong(json, "from");
                ulong to = optional_ulong(json, "to");
                uint max = optional_uint(json, "max");
                if (!bad_frame)
                    sync.inbound_history_req(peer, path, from, to, max, seq);
                break;
            }

            case "history":
                // node-to-node history recall isn't wired up yet - no outbound
                // requester exists to correlate this response with.
                log.info("inbound history frame from '", peer.name[], "' - ignored");
                break;

            case "enum":
            {
                const(char)[] type = require_str(json, "type");
                uint seq = optional_uint(json, "seq");
                Variant* members = json.getMember("members");
                Variant empty;
                if (!bad_frame)
                    sync.inbound_enum(peer, type, members ? *members : empty, seq);
                break;
            }

            case "log_sub":
            {
                const(char)[] sev_str = require_str(json, "severity");
                if (bad_frame)
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
                const(char)[] tag = optional_str(json, "tag");
                if (!bad_frame)
                    sync.inbound_log_sub(peer, sev, off, tag);
                break;
            }

            case "log":
            {
                Variant* msg_v = json.getMember("msg");
                if (!msg_v)
                    msg_v = json.getMember("payload"); // tolerate older browser clients
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
                uint seq = require_uint(json, "seq");
                if (!bad_frame)
                    sync.inbound_time_req(peer, seq);
                break;
            }

            case "time_resp":
            {
                // an incomplete response must never discipline the clock toward zero
                uint seq = require_uint(json, "seq");
                ulong recv = require_ulong(json, "recv");
                ulong xmit = require_ulong(json, "xmit");
                uint ver = require_uint(json, "ver");
                if (!bad_frame)
                    sync.inbound_time_resp(peer, seq, recv, xmit, ver);
                break;
            }

            case "time_push":
            {
                uint ver = require_uint(json, "ver");
                long delta = require_long(json, "delta");
                if (!bad_frame)
                    sync.inbound_time_push(peer, ver, delta);
                break;
            }

            default:
                log.warning("unknown kind: ", kind_str);
                break;
        }
        return true;
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

    void begin_frame(const(char)[] kind)
    {
        _buf.clear();
        _buf.append("{\"kind\":\"", kind, "\"");
    }

    int send_frame(SyncPeer peer, TxQueue queue = TxQueue.control)
    {
        _buf ~= '}';
        int r = peer.transmit_frame(cast(const(ubyte)[])_buf[], true, queue);
        if (r < 0)
        {
            // event-driven encodes (state/cmd/result/error/sub/...) have no retry path!!
            // a drop here means the peer permanently misses this event.
            const preview = _buf.length < 200 ? _buf.length : 200;
            log.warning("dropped frame to peer (", _buf.length, "B): ", cast(const(char)[])_buf[0 .. preview], _buf.length > 200 ? "..." : "");
        }
        return r;
    }

    void write_str(const(char)[] s)
    {
        const v = Variant(s);
        size_t n = v.write_json(null);
        v.write_json(_buf.extend(n));
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
        size_t n = v.write_json(null);
        v.write_json(_buf.extend(n));
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

    ulong peer_id;
    assert(JsonEncoder.parse_peer_id("0123456789abcdef", peer_id));
    assert(peer_id == 0x0123_4567_89AB_CDEF);
    assert(!JsonEncoder.parse_peer_id("", peer_id));
    assert(!JsonEncoder.parse_peer_id("123xyz", peer_id));
    assert(!JsonEncoder.parse_peer_id("0000000000000000", peer_id));
}
