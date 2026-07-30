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
import urt.mem.allocator;
import urt.meta.enuminfo : enum_key_from_value, enum_from_key, VoidEnumInfo;
import urt.string;
import urt.variant;

import manager.base;
import manager.collection;
import manager.element : Element;
import manager.record : Sample;
import manager.series : DataFormat, SeriesKind;
import manager.sync;
import manager.sync.encoder;
import manager.sync.peer;


nothrow @nogc:


__gshared JsonEncoder g_json_encoder;


final class JsonEncoder : SyncEncoder
{
nothrow @nogc:

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
        Variant v = p.get(obj);
        write_variant(v);
        if (seq)
            _buf.append(",\"seq\":", seq);
        send_frame(peer);
    }

    override void encode_set(SyncPeer peer, CID target, const(char)[] prop_name,
                             ref const Variant value, uint seq)
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
        send_frame(peer);
        return !_last_drop;
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
        send_frame(peer);
    }

    // Outbound: model plane

    override void encode_hello(SyncPeer peer)
    {
        import manager.system : hostname;

        begin_frame("hello");
        _buf.append(",\"ver\":", model_protocol_version);
        _buf.append(",\"host\":");
        write_str(hostname[]);
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

    override void encode_type_format(SyncPeer peer, uint ft, ref const DataFormat fmt)
    {
        import manager.sample : enum_info_name;

        begin_frame("type");
        _buf.append(",\"ft\":", ft);
        _buf.append(",\"format\":{\"type\":\"", value_type_name(fmt.type), '\"');
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

    override void encode_add(SyncPeer peer, SyncHandle h, const(char)[] path, const(char)[] node_class,
                             uint ft, Element* e)
    {
        import urt.time : unix_time_ns;
        import manager.element : Access, SamplingMode;

        begin_frame("add");
        _buf.append(",\"h\":", h);
        _buf ~= ",\"path\":";
        write_str(path);
        _buf.append(",\"class\":\"", node_class, '\"');
        if (e)
        {
            _buf.append(",\"ft\":", ft);
            if (e.access != Access.read)
                _buf.append(",\"access\":\"", enum_key_from_value!Access(e.access), '\"');
            if (e.sampling_mode != SamplingMode.manual)
                _buf.append(",\"mode\":\"", enum_key_from_value!SamplingMode(e.sampling_mode), '\"');
            Variant v = e.value;
            if (!v.isNull)
            {
                _buf ~= ",\"v\":";
                write_variant(v);
                _buf.append(",\"t\":", unix_time_ns(e.last_update) / 1_000_000);
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
        send_frame(peer);
    }

    override void encode_res(SyncPeer peer, uint seq)
    {
        begin_frame("res");
        _buf.append(",\"seq\":", seq);
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
        Variant json = parse_json(cast(char[])cast(const(char)[])frame);
        if (!json.isObject)
        {
            log.warning("sync/json: frame is not a JSON object");
            return;
        }

        const(char)[] kind_str = json.getMember("kind").asString();
        if (kind_str.length == 0)
        {
            log.warning("sync/json: frame missing 'kind' field");
            return;
        }

        switch (kind_str)
        {
            case "add_name":
                sync.inbound_add_name(peer,
                    cast(SyncHandle)json.getMember("h").asLong(),
                    json.getMember("name").asString(),
                    json.getMember("type").asString());
                break;

            case "bind":
            {
                CID target = peer.cid_of(cast(SyncHandle)json.getMember("target").asLong());
                const(char)[] type = json.getMember("type").asString();
                uint seq = cast(uint)json.getMember("seq").asLong();
                sync.inbound_bind(peer, target, type, seq);
                dispatch_props(peer, target, json);
                break;
            }

            case "unbind":
                sync.inbound_unbind(peer,
                    peer.cid_of(cast(SyncHandle)json.getMember("target").asLong()),
                    cast(uint)json.getMember("seq").asLong());
                break;

            case "create":
            {
                const(char)[] type = json.getMember("type").asString();
                uint seq = cast(uint)json.getMember("seq").asLong();

                Array!NamedArgument props;
                Variant* pv = json.getMember("props");
                if (pv && pv.isObject)
                    foreach (k, ref v; *pv)
                        props ~= NamedArgument(k, v);

                sync.inbound_create(peer, type, props[], seq);
                break;
            }

            case "destroy":
                sync.inbound_destroy(peer,
                    peer.cid_of(cast(SyncHandle)json.getMember("target").asLong()),
                    cast(uint)json.getMember("seq").asLong());
                break;

            case "state":
            {
                const(char)[] sig_str = json.getMember("signal").asString();
                const(StateSignal)* sig = enum_from_key!StateSignal(sig_str);
                if (!sig)
                {
                    log.warning("sync/json: unknown state signal: ", sig_str);
                    break;
                }
                sync.inbound_state(peer,
                    peer.cid_of(cast(SyncHandle)json.getMember("target").asLong()),
                    *sig);
                break;
            }

            case "set":
            {
                CID target = peer.cid_of(cast(SyncHandle)json.getMember("target").asLong());
                const(char)[] prop = json.getMember("prop").asString();
                uint seq = cast(uint)json.getMember("seq").asLong();
                Variant* val = json.getMember("value");
                if (!val)
                {
                    log.warning("sync/json: set missing 'value'");
                    break;
                }
                sync.inbound_set(peer, target, prop, *val, seq);
                break;
            }

            case "reset":
                sync.inbound_reset(peer,
                    peer.cid_of(cast(SyncHandle)json.getMember("target").asLong()),
                    json.getMember("prop").asString(),
                    cast(uint)json.getMember("seq").asLong());
                break;

            case "cmd":
                sync.inbound_cmd(peer,
                    cast(uint)json.getMember("seq").asLong(),
                    json.getMember("text").asString());
                break;

            case "result":
            {
                uint seq = cast(uint)json.getMember("seq").asLong();
                Variant* val = json.getMember("value");
                Variant empty;
                sync.inbound_result(peer, seq,
                    val ? *val : empty,
                    json.getMember("text").asString());
                break;
            }

            case "error":
                sync.inbound_error(peer,
                    cast(uint)json.getMember("seq").asLong(),
                    json.getMember("text").asString());
                break;

            case "sub":
            {
                Variant* pats = json.getMember("patterns");
                if (pats && pats.isArray)
                {
                    Array!(const(char)[]) patterns;
                    for (size_t i = 0; i < pats.length(); ++i)
                        patterns ~= (*pats)[i].asString();
                    Variant* once = json.getMember("once");
                    sync.inbound_model_sub(peer,
                        cast(uint)json.getMember("seq").asLong(),
                        patterns[],
                        once && once.asBool());
                    break;
                }
                sync.inbound_sub(peer,
                    json.getMember("pattern").asString().makeString(defaultAllocator));
                break;
            }

            case "hello":
            {
                ubyte caps;
                Variant* cv = json.getMember("caps");
                if (cv && cv.isArray)
                {
                    for (size_t i = 0; i < cv.length(); ++i)
                    {
                        const(SyncCaps)* c = enum_from_key!SyncCaps((*cv)[i].asString());
                        if (c)
                            caps |= *c;
                    }
                }
                Variant* mf = json.getMember("max_frame");
                sync.inbound_hello(peer,
                    cast(uint)json.getMember("ver").asLong(),
                    json.getMember("host").asString(),
                    caps,
                    mf ? cast(uint)mf.asLong() : 0);
                break;
            }

            case "type":
            {
                Variant* fmt = json.getMember("format");
                if (fmt && fmt.isObject)
                {
                    WireFormat wf;
                    wf.type = fmt.getMember("type").asString();
                    wf.series = fmt.getMember("series").asString();
                    Variant* c = fmt.getMember("count");
                    wf.count = c ? cast(ubyte)c.asLong() : 1;
                    Variant* r = fmt.getMember("rate");
                    wf.rate = r ? cast(uint)r.asLong() : 0;
                    Variant* u = fmt.getMember("unit");
                    wf.unit = u ? u.asString() : null;
                    Variant* en = fmt.getMember("enum");
                    wf.enum_name = en ? en.asString() : null;
                    sync.inbound_type_format(peer,
                        cast(uint)json.getMember("ft").asLong(), wf);
                    break;
                }
                Variant* members = json.getMember("members");
                Variant empty;
                sync.inbound_type_enum(peer,
                    json.getMember("name").asString(),
                    members ? *members : empty);
                break;
            }

            case "add":
            {
                Variant* ft = json.getMember("ft");
                Variant* acc = json.getMember("access");
                Variant* mode = json.getMember("mode");
                Variant* t = json.getMember("t");
                sync.inbound_model_add(peer,
                    cast(SyncHandle)json.getMember("h").asLong(),
                    json.getMember("path").asString(),
                    json.getMember("class").asString(),
                    ft ? cast(uint)ft.asLong() : uint.max,
                    acc ? acc.asString() : null,
                    mode ? mode.asString() : null,
                    json.getMember("v"),
                    t ? cast(ulong)t.asLong() : 0);
                break;
            }

            case "val":
            {
                Variant* s = json.getMember("s");
                if (!s || !s.isArray)
                {
                    log.warning("sync/json: val missing sample array");
                    break;
                }
                SyncHandle h = cast(SyncHandle)json.getMember("h").asLong();
                for (size_t i = 0; i < s.length(); ++i)
                {
                    ref Variant pair = (*s)[i];
                    if (!pair.isArray || pair.length() < 2)
                        continue;
                    sync.inbound_val(peer, h, pair[1], cast(ulong)pair[0].asLong());
                }
                break;
            }

            case "res":
                sync.inbound_res(peer, cast(uint)json.getMember("seq").asLong());
                break;

            case "err":
            {
                Variant* code = json.getMember("code");
                sync.inbound_err(peer,
                    cast(uint)json.getMember("seq").asLong(),
                    code ? code.asString() : null,
                    json.getMember("text").asString());
                break;
            }

            case "unsub":
                sync.inbound_unsub(peer, json.getMember("pattern").asString());
                break;

            case "enum_req":
                sync.inbound_enum_req(peer, json.getMember("type").asString(),
                    cast(uint)json.getMember("seq").asLong());
                break;

            case "history_req":
            {
                Variant* from = json.getMember("from");
                Variant* to = json.getMember("to");
                Variant* max = json.getMember("max");
                sync.inbound_history_req(peer,
                    json.getMember("path").asString(),
                    from ? cast(ulong)from.asLong() : 0,
                    to ? cast(ulong)to.asLong() : 0,
                    max ? cast(uint)max.asLong() : 0,
                    cast(uint)json.getMember("seq").asLong());
                break;
            }

            case "history":
                // node-to-node history recall isn't wired up yet - no outbound
                // requester exists to correlate this response with.
                log.info("sync/json: inbound history frame from '", peer.name[], "' - ignored");
                break;

            case "enum":
            {
                uint seq = cast(uint)json.getMember("seq").asLong();
                Variant* members = json.getMember("members");
                Variant empty;
                sync.inbound_enum(peer,
                    json.getMember("type").asString(),
                    members ? *members : empty, seq);
                break;
            }

            case "log_sub":
            {
                Variant* sev_v = json.getMember("severity");
                if (!sev_v || !sev_v.isString)
                {
                    log.warning("sync/json: log_sub missing string 'severity'");
                    break;
                }

                const(char)[] sev_str = sev_v.asString();
                bool off = sev_str == "off";
                Severity sev = Severity.info;
                if (!off)
                {
                    const(Severity)* s = enum_from_key!Severity(sev_str);
                    if (!s)
                    {
                        log.warning("sync/json: unknown log_sub severity: ", sev_str);
                        break;
                    }
                    sev = *s;
                }

                Variant* tag_v = json.getMember("tag");
                if (tag_v && !tag_v.isNull && !tag_v.isString)
                {
                    log.warning("sync/json: log_sub 'tag' is not a string");
                    break;
                }
                sync.inbound_log_sub(peer, sev, off, tag_v && tag_v.isString ? tag_v.asString() : null);
                break;
            }

            case "log":
            {
                Variant* msg_v = json.getMember("msg");
                if (!msg_v)
                    msg_v = json.getMember("payload"); // tolerate older browser clients
                if (!msg_v || !msg_v.isString)
                {
                    log.warning("sync/json: log missing string 'msg'");
                    break;
                }
                sync.inbound_log(peer, msg_v.asString());
                break;
            }

            case "time_req":
                sync.inbound_time_req(peer, cast(uint)json.getMember("seq").asLong());
                break;

            case "time_resp":
                sync.inbound_time_resp(peer,
                    cast(uint)json.getMember("seq").asLong(),
                    cast(ulong)json.getMember("recv").asLong(),
                    cast(ulong)json.getMember("xmit").asLong(),
                    cast(uint)json.getMember("ver").asLong());
                break;

            case "time_push":
                sync.inbound_time_push(peer,
                    cast(uint)json.getMember("ver").asLong(),
                    json.getMember("delta").asLong());
                break;

            default:
                log.warning("sync/json: unknown kind: ", kind_str);
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

                if (_last_drop)
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
    bool _last_drop;

    void begin_frame(const(char)[] kind)
    {
        _buf.clear();
        _buf.append("{\"kind\":\"", kind, "\"");
    }

    void send_frame(SyncPeer peer)
    {
        _buf ~= '}';
        _last_drop = peer.transmit_frame(cast(const(ubyte)[])_buf[], true) < 0;
        if (_last_drop)
        {
            // event-driven encodes (state/cmd/result/error/sub/...) have no retry path!!
            // a drop here means the peer permanently misses this event.
            const preview = _buf.length < 200 ? _buf.length : 200;
            log.warning("dropped frame to peer (", _buf.length, "B): ", cast(const(char)[])_buf[0 .. preview], _buf.length > 200 ? "..." : "");
        }
    }

    void write_str(const(char)[] s)
    {
        const v = Variant(s);
        size_t n = v.write_json(null);
        v.write_json(_buf.extend(n));
    }

    void write_variant(ref const Variant v)
    {
        size_t n = v.write_json(null);
        v.write_json(_buf.extend(n));
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
            Variant val = p.get(obj);
            write_variant(val);
        }
        if (any)
            _buf ~= '}';
    }
}
