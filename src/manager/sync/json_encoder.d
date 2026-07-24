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
import urt.meta.enuminfo : enum_key_from_value, enum_from_key;
import urt.string;
import urt.variant;

import manager.base;
import manager.collection;
import manager.record : Sample;
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

    override void encode_rename(SyncPeer peer, BaseObject obj)
    {
        uint handle = peer.handle_of(obj);
        if (handle == SyncPeer.invalid_handle)
            return;
        begin_frame("rename");
        _buf.append(",\"target\":", handle);
        _buf.append(",\"name\":");
        write_str(obj.name[]);
        send_frame(peer);
    }

    // Outbound: mirror lifecycle

    override void encode_bind(SyncPeer peer, BaseObject obj, uint seq)
    {
        uint h = peer.handle_of(obj);
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

    override void encode_log(SyncPeer peer, const(char)[] line)
    {
        begin_frame("log");
        _buf.append(",\"msg\":");
        write_str(line);
        send_frame(peer);
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
                    cast(uint)json.getMember("h").asLong(),
                    json.getMember("name").asString(),
                    json.getMember("type").asString());
                break;

            case "rename":
                sync.inbound_rename(peer,
                    cast(uint)json.getMember("target").asLong(),
                    json.getMember("name").asString());
                break;

            case "bind":
            {
                CID target = peer.cid_of(cast(uint)json.getMember("target").asLong());
                const(char)[] type = json.getMember("type").asString();
                uint seq = cast(uint)json.getMember("seq").asLong();
                sync.inbound_bind(peer, target, type, seq);
                dispatch_props(peer, target, json);
                break;
            }

            case "unbind":
                sync.inbound_unbind(peer,
                    peer.cid_of(cast(uint)json.getMember("target").asLong()),
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
                    peer.cid_of(cast(uint)json.getMember("target").asLong()),
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
                    peer.cid_of(cast(uint)json.getMember("target").asLong()),
                    *sig);
                break;
            }

            case "set":
            {
                CID target = peer.cid_of(cast(uint)json.getMember("target").asLong());
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
                    peer.cid_of(cast(uint)json.getMember("target").asLong()),
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
                sync.inbound_sub(peer,
                    json.getMember("pattern").asString().makeString(defaultAllocator));
                break;

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
