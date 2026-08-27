module manager.sync.binary_encoder;

// BinaryEncoder - packed binary framing for node-to-node sync over byte
// transports (serial, UDP, shmem rings). Same verb surface and dispatch
// contract as JsonEncoder; a frame is [verb u8][fields], integers travel as
// LEB128 varints (zigzag where signed), strings are length-prefixed, and
// values use a small tagged Variant codec. Types the codec doesn't model
// natively (quantities, enums, user types) travel as their string form -
// the same fidelity the JSON channel has, and property setters parse them.

import urt.array;
import urt.log;
import urt.mem;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.string;
import urt.variant;

import manager.base;
import manager.collection;
import manager.element : Element;
import manager.record : Sample;
import manager.series : Constraint, DataFormat, RecordBlock, Scalar, SeriesKind, ValueType;
import manager.sync;
import manager.sync.encoder;
import manager.sync.peer;


nothrow @nogc:


__gshared BinaryEncoder g_binary_encoder;


// JSON overloads several verbs by field-shape (set/model_set, sub/model_sub,
// type format/enum); the binary channel gives each shape its own verb byte.
enum Verb : ubyte
{
    add_name,
    bind,
    unbind,
    create,
    destroy,
    state,
    set,
    reset,
    cmd,
    result,
    error,
    sub,
    unsub,
    enum_req,
    enum_,
    history_req,
    history,
    log_sub,
    log,
    time_req,
    time_resp,
    time_push,
    hello,
    model_sub,
    model_unsub,
    type_format,
    type_enum,
    add,
    val,
    model_set,
    res,
    err,
    suggest,
    suggestions,
    claim,
}


final class BinaryEncoder : SyncEncoder
{
nothrow @nogc:

    alias log = Log!"sync.bin";

    SyncModule sync;

    this(SyncModule sync)
    {
        this.sync = sync;
    }

    // Outbound: registry

    override void encode_add_name(SyncPeer peer, BaseObject obj)
    {
        begin_frame(Verb.add_name);
        _buf.put_varint(peer.introduce(obj));
        _buf.put_str(obj.name[]);
        _buf.put_str(obj.type[]);
        send_frame(peer);
    }

    // Outbound: mirror lifecycle

    override void encode_bind(SyncPeer peer, BaseObject obj, uint seq)
    {
        SyncHandle h = peer.handle_of(obj);
        debug assert(h != SyncPeer.invalid_handle, "bind without prior add_name");
        begin_frame(Verb.bind);
        _buf.put_varint(h);
        _buf.put_str(obj.type[]);
        _buf.put_varint(seq);

        // props as (name, value) pairs, empty-name terminated; all SET props
        // including read-only ones - proxies can't recompute derived state
        auto props = obj.properties();
        ulong set_bits = obj.props_set;
        foreach (i, p; props)
        {
            if (!(set_bits & (ulong(1) << i)) || !p.get || p.name[] == "type")
                continue;
            _buf.put_str(p.name[]);
            Variant v = p.get(obj, *p);
            _buf.put_variant(v);
        }
        _buf.put_str(null);
        send_frame(peer);
    }

    override void encode_unbind(SyncPeer peer, CID target, uint seq)
    {
        begin_frame(Verb.unbind);
        _buf.put_varint(peer.handle_of(target));
        _buf.put_varint(seq);
        send_frame(peer);
    }

    override void encode_create(SyncPeer peer, const(char)[] type, NamedArgument[] props, uint seq)
    {
        begin_frame(Verb.create);
        _buf.put_varint(seq);
        _buf.put_str(type);
        foreach (ref arg; props)
        {
            _buf.put_str(arg.name[]);
            _buf.put_variant(arg.value);
        }
        _buf.put_str(null);
        send_frame(peer);
    }

    override void encode_destroy(SyncPeer peer, CID target, uint seq)
    {
        begin_frame(Verb.destroy);
        _buf.put_varint(peer.handle_of(target));
        _buf.put_varint(seq);
        send_frame(peer);
    }

    // Outbound: state + property

    override void encode_state(SyncPeer peer, CID target, StateSignal sig)
    {
        begin_frame(Verb.state);
        _buf.put_varint(peer.handle_of(target));
        _buf ~= cast(ubyte)sig;
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

        begin_frame(Verb.set);
        _buf.put_varint(peer.handle_of(obj));
        _buf.put_str(p.name[]);
        Variant v = p.get(obj, *p);
        _buf.put_variant(v);
        _buf.put_varint(seq);
        send_frame(peer);
    }

    override void encode_set(SyncPeer peer, CID target, const(char)[] prop_name, ref const Variant value, uint seq)
    {
        begin_frame(Verb.set);
        _buf.put_varint(peer.handle_of(target));
        _buf.put_str(prop_name);
        _buf.put_variant(value);
        _buf.put_varint(seq);
        send_frame(peer);
    }

    override void encode_reset(SyncPeer peer, CID target, const(char)[] prop_name, uint seq)
    {
        begin_frame(Verb.reset);
        _buf.put_varint(peer.handle_of(target));
        _buf.put_str(prop_name);
        _buf.put_varint(seq);
        send_frame(peer);
    }

    // Outbound: commands, errors, enums, subscriptions

    override void encode_cmd(SyncPeer peer, uint seq, const(char)[] text)
    {
        begin_frame(Verb.cmd);
        _buf.put_varint(seq);
        _buf.put_str(text);
        send_frame(peer);
    }

    override void encode_result(SyncPeer peer, uint seq, ref const Variant value, const(char)[] out_text)
    {
        begin_frame(Verb.result);
        _buf.put_varint(seq);
        _buf.put_variant(value);
        _buf.put_str(out_text);
        send_frame(peer);
    }

    override void encode_error(SyncPeer peer, uint seq, const(char)[] text)
    {
        begin_frame(Verb.error);
        _buf.put_varint(seq);
        _buf.put_str(text);
        send_frame(peer);
    }

    override void encode_suggest(SyncPeer peer, uint seq, const(char)[] text)
    {
        begin_frame(Verb.suggest);
        _buf.put_varint(seq);
        _buf.put_str(text);
        send_frame(peer);
    }

    override void encode_suggestions(SyncPeer peer, uint seq, const(String)[] suggestions, const(char)[] completed)
    {
        begin_frame(Verb.suggestions);
        _buf.put_varint(seq);
        _buf.put_str(completed);
        _buf.put_varint(suggestions.length);
        foreach (ref suggestion; suggestions)
            _buf.put_str(suggestion[]);
        send_frame(peer);
    }

    override void encode_sub(SyncPeer peer, const(char)[] pattern)
    {
        begin_frame(Verb.sub);
        _buf.put_str(pattern);
        send_frame(peer);
    }

    override void encode_unsub(SyncPeer peer, const(char)[] pattern)
    {
        begin_frame(Verb.unsub);
        _buf.put_str(pattern);
        send_frame(peer);
    }

    override void encode_enum_req(SyncPeer peer, const(char)[] type_name, uint seq)
    {
        begin_frame(Verb.enum_req);
        _buf.put_str(type_name);
        _buf.put_varint(seq);
        send_frame(peer);
    }

    override void encode_enum(SyncPeer peer, const(char)[] type_name, ref const Variant members, uint seq)
    {
        begin_frame(Verb.enum_);
        _buf.put_str(type_name);
        _buf.put_varint(seq);
        _buf.put_variant(members);
        send_frame(peer);
    }

    override void encode_history_req(SyncPeer peer, const(char)[] path, ulong from_ms, ulong to_ms, uint max_points, uint seq)
    {
        begin_frame(Verb.history_req);
        _buf.put_str(path);
        _buf.put_varint(from_ms);
        _buf.put_varint(to_ms);
        _buf.put_varint(max_points);
        _buf.put_varint(seq);
        send_frame(peer);
    }

    override void encode_history(SyncPeer peer, uint seq, const(char)[] path, const(Sample)[] samples)
    {
        begin_frame(Verb.history);
        _buf.put_varint(seq);
        _buf.put_str(path);
        _buf.put_varint(samples.length);
        foreach (ref s; samples)
        {
            _buf.put_varint(s.time / 1_000_000);
            _buf.put_f64(s.value);
        }
        send_frame(peer);
    }

    // Outbound: log streaming

    override void encode_log_sub(SyncPeer peer, Severity max_severity, bool off, const(char)[] tag)
    {
        begin_frame(Verb.log_sub);
        _buf ~= off ? ubyte(0xFF) : cast(ubyte)max_severity;
        _buf.put_str(tag);
        send_frame(peer);
    }

    override bool encode_log(SyncPeer peer, const(char)[] line)
    {
        begin_frame(Verb.log);
        _buf.put_str(line);
        return send_frame(peer, TxQueue.log) >= 0;
    }

    // Outbound: time sync

    override void encode_time_req(SyncPeer peer, uint seq)
    {
        begin_frame(Verb.time_req);
        _buf.put_varint(seq);
        send_frame(peer);
    }

    override void encode_time_resp(SyncPeer peer, uint seq, ulong recv_ns, ulong xmit_ns, uint ver)
    {
        begin_frame(Verb.time_resp);
        _buf.put_varint(seq);
        _buf.put_varint(recv_ns);
        _buf.put_varint(xmit_ns);
        _buf.put_varint(ver);
        send_frame(peer);
    }

    override void encode_time_push(SyncPeer peer, uint ver, long delta_ns)
    {
        begin_frame(Verb.time_push);
        _buf.put_varint(ver);
        _buf.put_zigzag(delta_ns);
        send_frame(peer);   // control: staleness corrupts collection timestamps until repaired
    }

    // Outbound: model plane

    override void encode_hello(SyncPeer peer)
    {
        import manager : get_module;
        import manager.system : hostname, node_id;
        import manager.sync.discovery : SyncDiscoveryModule;

        begin_frame(Verb.hello);
        _buf.put_varint(model_protocol_version);
        _buf.put_str(hostname[]);
        _buf ~= local_sync_caps;
        _buf.put_varint(max_frame_size);

        // identity tail; pre-identity decoders stop at max_frame and ignore it
        auto disco = get_module!SyncDiscoveryModule;
        _buf.put_varint(node_id());
        _buf ~= disco.local_role;
        _buf.put_str(disco.local_cluster[]);
        _buf.put_str(cast(const(char)[])peer.local_nonce());
        send_frame(peer);
    }

    override void encode_claim(SyncPeer peer, uint seq, const(char)[] cluster, uint priority, const(char)[] auth, const(char)[] key)
    {
        begin_frame(Verb.claim);
        _buf.put_varint(seq);
        _buf.put_str(cluster);
        _buf.put_varint(priority);
        _buf.put_str(auth);
        _buf.put_str(key);
        send_frame(peer);
    }

    override void encode_model_sub(SyncPeer peer, uint seq, const(char[])[] patterns, bool once)
    {
        begin_frame(Verb.model_sub);
        _buf.put_varint(seq);
        _buf ~= ubyte(once);
        _buf.put_varint(0);   // from_ms
        _buf.put_varint(0);   // to_ms
        _buf.put_varint(patterns.length);
        foreach (p; patterns)
            _buf.put_str(p);
        send_frame(peer);
    }

    override void encode_type_format(SyncPeer peer, uint ft, ref const DataFormat fmt)
    {
        import urt.mem.temp : tconcat;
        import manager.sample : enum_info_name;

        begin_frame(Verb.type_format);
        _buf.put_varint(ft);
        _buf.put_str(wire_type_name(fmt));
        _buf.put_str(enum_key_name!SeriesKind(fmt.kind));
        _buf ~= fmt.count;
        _buf.put_varint(fmt.rate);
        _buf.put_str(fmt.desc == DataFormat.Desc.quantity ? tconcat(fmt.unit) : null);
        _buf.put_str(fmt.desc == DataFormat.Desc.enum_ ? enum_info_name(fmt.enum_info) : null);

        Variant min, max, step;
        if (fmt.constraint && fmt.is_scalar)
        {
            ref const Constraint c = *fmt.constraint;
            if (c.has & Constraint.Has.min)
                min = scalar_variant(c.min, fmt.type);
            if (c.has & Constraint.Has.max)
                max = scalar_variant(c.max, fmt.type);
            if (c.has & Constraint.Has.step)
                step = scalar_variant(c.step, fmt.type);
        }
        _buf.put_variant(min);
        _buf.put_variant(max);
        _buf.put_variant(step);
        send_frame(peer);
    }

    override void encode_type_enum(SyncPeer peer, const(char)[] name, const(VoidEnumInfo)* info)
    {
        begin_frame(Verb.type_enum);
        _buf.put_str(name);
        _buf.put_varint(info.count);
        foreach (i; 0 .. info.count)
        {
            const(char)[] key = info.key_by_decl_index(i);
            _buf.put_str(key);
            _buf.put_zigzag(info.value_for(key).asLong);
        }
        send_frame(peer);
    }

    override void encode_add(SyncPeer peer, SyncHandle h, const(char)[] path, const(char)[] node_class, uint ft, Element* e, ulong peer_id)
    {
        import urt.time : unix_time_ns;
        import manager.element : Access;

        begin_frame(Verb.add);
        _buf.put_varint(h);
        _buf.put_str(path);
        _buf.put_str(node_class);
        _buf ~= ubyte(e !is null);
        if (e)
        {
            _buf.put_varint(ft);
            _buf.put_str(e.access != Access.read ? enum_key_name!Access(e.access) : null);
            _buf.put_str(null); // Version 1 reserved this slot for sampling mode.

            Variant v;
            ulong t_ms = 0;
            if (e.data_format.kind != SeriesKind.point)
            {
                // events retain no value; occurrences replay via backfill
                v = e.value;
                if (!v.isNull)
                    t_ms = unix_time_ns(e.last_update) / 1_000_000;
            }
            _buf.put_variant(v);
            _buf.put_varint(t_ms);
        }
        _buf.put_varint(peer_id);
        send_frame(peer);
    }

    override void encode_val(SyncPeer peer, SyncHandle h, Element* e)
    {
        import urt.time : unix_time_ns;

        begin_frame(Verb.val);
        _buf.put_varint(h);
        _buf.put_varint(0);   // lost
        _buf.put_varint(1);
        _buf.put_varint(unix_time_ns(e.last_update) / 1_000_000);
        Variant v = e.value;
        _buf.put_variant(v);
        send_frame(peer, TxQueue.val);
    }

    override void encode_val_block(SyncPeer peer, SyncHandle h, ref const RecordBlock blk)
    {
        import urt.time : unix_time_ns;

        begin_frame(Verb.val);
        _buf.put_varint(h);
        _buf.put_varint(blk.lost);
        _buf.put_varint(blk.count);
        foreach (i; 0 .. blk.count)
        {
            _buf.put_varint(unix_time_ns(blk.time(i)) / 1_000_000);
            Variant v = blk.box(i);
            _buf.put_variant(v);
        }
        send_frame(peer, TxQueue.val);
    }

    override void encode_res(SyncPeer peer, uint seq)
    {
        begin_frame(Verb.res);
        _buf.put_varint(seq);
        Variant none;
        _buf.put_variant(none);
        send_frame(peer);
    }

    override void encode_res(SyncPeer peer, uint seq, ref const Variant value)
    {
        begin_frame(Verb.res);
        _buf.put_varint(seq);
        _buf.put_variant(value);
        send_frame(peer);
    }

    override void encode_err(SyncPeer peer, uint seq, const(char)[] code, const(char)[] text)
    {
        begin_frame(Verb.err);
        _buf.put_varint(seq);
        _buf.put_str(code);
        _buf.put_str(text);
        send_frame(peer);
    }

    // Inbound

    override bool decode_and_dispatch(SyncPeer peer, const(ubyte)[] frame)
    {
        if (frame.length == 0)
            return true;
        if (frame[0] > Verb.max)
        {
            log.warning("unknown verb ", frame[0]);
            return true;
        }
        Verb verb = cast(Verb)frame[0];
        Reader r = Reader(frame[1 .. $]);

        final switch (verb)
        {
            case Verb.add_name:
            {
                SyncHandle h = r.varint();
                const(char)[] name = r.str();
                const(char)[] type = r.str();
                if (r.fail)
                    break;
                sync.inbound_add_name(peer, h, name, type);
                break;
            }

            case Verb.bind:
            {
                CID target = peer.cid_of(r.varint());
                const(char)[] type = r.str();
                uint seq = cast(uint)r.varint();
                if (r.fail)
                    break;
                sync.inbound_bind(peer, target, type, seq);
                for (;;)
                {
                    const(char)[] prop = r.str();
                    if (r.fail || prop.length == 0)
                        break;
                    Variant v = r.variant();
                    if (r.fail)
                        break;
                    sync.inbound_set(peer, target, prop, v, 0);
                }
                break;
            }

            case Verb.unbind:
            {
                CID target = peer.cid_of(r.varint());
                uint seq = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_unbind(peer, target, seq);
                break;
            }

            case Verb.create:
            {
                uint seq = cast(uint)r.varint();
                const(char)[] type = r.str();
                Array!NamedArgument props;
                for (;;)
                {
                    const(char)[] prop = r.str();
                    if (r.fail || prop.length == 0)
                        break;
                    Variant v = r.variant();
                    if (r.fail)
                        break;
                    props ~= NamedArgument(prop, v.move);
                }
                if (!r.fail)
                    sync.inbound_create(peer, type, props[], seq);
                break;
            }

            case Verb.destroy:
            {
                CID target = peer.cid_of(r.varint());
                uint seq = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_destroy(peer, target, seq);
                break;
            }

            case Verb.state:
            {
                CID target = peer.cid_of(r.varint());
                ubyte sig = r.u8();
                if (r.fail)
                    break;
                if (sig > StateSignal.offline)
                {
                    log.warning("bad state signal ", sig);
                    break;
                }
                sync.inbound_state(peer, target, cast(StateSignal)sig);
                break;
            }

            case Verb.set:
            {
                CID target = peer.cid_of(r.varint());
                const(char)[] prop = r.str();
                Variant v = r.variant();
                uint seq = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_set(peer, target, prop, v, seq);
                break;
            }

            case Verb.reset:
            {
                CID target = peer.cid_of(r.varint());
                const(char)[] prop = r.str();
                uint seq = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_reset(peer, target, prop, seq);
                break;
            }

            case Verb.cmd:
            {
                uint seq = cast(uint)r.varint();
                const(char)[] text = r.str();
                if (!r.fail)
                    sync.inbound_cmd(peer, seq, text);
                break;
            }

            case Verb.result:
            {
                uint seq = cast(uint)r.varint();
                Variant v = r.variant();
                const(char)[] text = r.str();
                if (!r.fail)
                    sync.inbound_result(peer, seq, v, text);
                break;
            }

            case Verb.error:
            {
                uint seq = cast(uint)r.varint();
                const(char)[] text = r.str();
                if (!r.fail)
                    sync.inbound_error(peer, seq, text);
                break;
            }

            case Verb.sub:
            {
                const(char)[] pattern = r.str();
                if (!r.fail)
                    sync.inbound_sub(peer, pattern.make_string());
                break;
            }

            case Verb.unsub:
            {
                const(char)[] pattern = r.str();
                if (!r.fail)
                    sync.inbound_unsub(peer, pattern);
                break;
            }

            case Verb.enum_req:
            {
                const(char)[] type = r.str();
                uint seq = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_enum_req(peer, type, seq);
                break;
            }

            case Verb.enum_:
            {
                const(char)[] type = r.str();
                uint seq = cast(uint)r.varint();
                Variant members = r.variant();
                if (!r.fail)
                    sync.inbound_enum(peer, type, members, seq);
                break;
            }

            case Verb.history_req:
            {
                const(char)[] path = r.str();
                ulong from_ms = r.varint();
                ulong to_ms = r.varint();
                uint max_points = cast(uint)r.varint();
                uint seq = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_history_req(peer, path, from_ms, to_ms, max_points, seq);
                break;
            }

            case Verb.history:
                // node-to-node history recall isn't wired up yet - no outbound
                // requester exists to correlate this response with.
                log.info("inbound history frame from '", peer.name[], "' - ignored");
                break;

            case Verb.log_sub:
            {
                ubyte sev = r.u8();
                const(char)[] tag = r.str();
                if (r.fail)
                    break;
                bool off = sev == 0xFF;
                if (!off && sev > Severity.max)
                {
                    log.warning("bad log_sub severity ", sev);
                    break;
                }
                sync.inbound_log_sub(peer, off ? Severity.info : cast(Severity)sev, off, tag);
                break;
            }

            case Verb.log:
            {
                const(char)[] line = r.str();
                if (!r.fail)
                    sync.inbound_log(peer, line);
                break;
            }

            case Verb.time_req:
            {
                uint seq = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_time_req(peer, seq);
                break;
            }

            case Verb.time_resp:
            {
                uint seq = cast(uint)r.varint();
                ulong recv_ns = r.varint();
                ulong xmit_ns = r.varint();
                uint ver = cast(uint)r.varint();
                if (!r.fail)
                    sync.inbound_time_resp(peer, seq, recv_ns, xmit_ns, ver);
                break;
            }

            case Verb.time_push:
            {
                uint ver = cast(uint)r.varint();
                long delta = r.zigzag();
                if (!r.fail)
                    sync.inbound_time_push(peer, ver, delta);
                break;
            }

            case Verb.hello:
            {
                import manager.sync.discovery : PeerRole;

                uint ver = cast(uint)r.varint();
                const(char)[] host = r.str();
                ubyte caps = r.u8();
                uint max_frame = cast(uint)r.varint();

                ulong nid = 0;
                PeerRole role;
                const(char)[] cluster;
                const(ubyte)[] nonce;
                if (!r.fail && r.more)
                {
                    nid = r.varint();
                    ubyte rb = r.u8();
                    if (rb <= PeerRole.max)
                        role = cast(PeerRole)rb;
                    cluster = r.str();
                    if (!r.fail && r.more)
                        nonce = cast(const(ubyte)[])r.str();
                }
                if (!r.fail)
                    sync.inbound_hello(peer, ver, host, caps, max_frame, nid, role, cluster, nonce);
                break;
            }

            case Verb.claim:
            {
                uint seq = cast(uint)r.varint();
                const(char)[] cluster = r.str();
                uint priority = cast(uint)r.varint();
                const(char)[] auth = r.str();
                const(char)[] key = r.more ? r.str() : null;
                if (!r.fail)
                    sync.inbound_claim(peer, seq, cluster, priority, auth, key);
                break;
            }

            case Verb.model_sub:
            {
                uint seq = cast(uint)r.varint();
                bool once = r.u8() != 0;
                ulong from_ms = r.varint();
                ulong to_ms = r.varint();
                size_t count = cast(size_t)r.varint();
                if (r.fail || count > max_frame_size)
                    break;
                Array!(const(char)[]) patterns;
                foreach (i; 0 .. count)
                    patterns ~= r.str();
                if (!r.fail)
                    sync.inbound_model_sub(peer, seq, patterns[], once, from_ms, to_ms);
                break;
            }

            case Verb.model_unsub:
            {
                size_t count = cast(size_t)r.varint();
                if (r.fail || count > max_frame_size)
                    break;
                Array!(const(char)[]) patterns;
                foreach (i; 0 .. count)
                    patterns ~= r.str();
                if (!r.fail)
                    sync.inbound_model_unsub(peer, patterns[]);
                break;
            }

            case Verb.type_format:
            {
                uint ft = cast(uint)r.varint();
                WireFormat wf;
                wf.type = r.str();
                wf.series = r.str();
                wf.count = r.u8();
                wf.rate = cast(uint)r.varint();
                wf.unit = r.str();
                wf.enum_name = r.str();
                wf.min = r.variant();
                wf.max = r.variant();
                wf.step = r.variant();
                if (!r.fail)
                    sync.inbound_type_format(peer, ft, wf);
                break;
            }

            case Verb.type_enum:
            {
                const(char)[] name = r.str();
                size_t count = cast(size_t)r.varint();
                if (r.fail || count > max_frame_size)
                    break;
                Variant members;
                foreach (i; 0 .. count)
                {
                    const(char)[] key = r.str();
                    long value = r.zigzag();
                    if (r.fail)
                        break;
                    members.insert(key, Variant(value));
                }
                if (!r.fail)
                    sync.inbound_type_enum(peer, name, members);
                break;
            }

            case Verb.add:
            {
                SyncHandle h = r.varint();
                const(char)[] path = r.str();
                const(char)[] node_class = r.str();
                bool has_element = r.u8() != 0;
                uint ft = uint.max;
                const(char)[] access;
                Variant v;
                ulong t_ms = 0;
                ulong peer_id;
                if (has_element)
                {
                    ft = cast(uint)r.varint();
                    access = r.str();
                    r.str();
                    v = r.variant();
                    t_ms = r.varint();
                }
                if (r.more())
                    peer_id = r.varint();
                if (!r.fail)
                {
                    Variant* value = v.isNull ? null : &v;
                    sync.inbound_model_add(peer, h, path, node_class, ft, access, value, t_ms, peer_id);
                }
                break;
            }

            case Verb.val:
            {
                SyncHandle h = r.varint();
                r.varint();   // lost - informational, mirror ignores it (same as JSON)
                size_t count = cast(size_t)r.varint();
                if (r.fail || count > max_frame_size)
                    break;
                foreach (i; 0 .. count)
                {
                    ulong t_ms = r.varint();
                    Variant v = r.variant();
                    if (r.fail)
                        break;
                    if (!sync.inbound_val(peer, h, v, t_ms))
                        return false;
                }
                break;
            }

            case Verb.model_set:
            {
                uint seq = cast(uint)r.varint();
                SyncHandle h = r.varint();
                const(char)[] path = r.str();
                bool reset_ = r.u8() != 0;
                Variant v = r.variant();
                if (!r.fail)
                    sync.inbound_model_set(peer, seq, h, path, v.isNull ? null : &v, reset_);
                break;
            }

            case Verb.res:
            {
                uint seq = cast(uint)r.varint();
                r.variant();
                if (!r.fail)
                    sync.inbound_res(peer, seq);
                break;
            }

            case Verb.err:
            {
                uint seq = cast(uint)r.varint();
                const(char)[] code = r.str();
                const(char)[] text = r.str();
                if (!r.fail)
                    sync.inbound_err(peer, seq, code, text);
                break;
            }

            case Verb.suggest:
            {
                uint seq = cast(uint)r.varint();
                const(char)[] text = r.str();
                if (!r.fail)
                    sync.inbound_suggest(peer, seq, text);
                break;
            }

            case Verb.suggestions:
            {
                r.varint();
                r.str();
                size_t count = cast(size_t)r.varint();
                if (r.fail || count > max_frame_size)
                    break;
                foreach (i; 0 .. count)
                    r.str();
                break;
            }
        }

        if (r.fail)
            log.warning("truncated or malformed '", enum_key_name!Verb(verb), "' frame from '", peer.name[], "'");
        return true;
    }

    // Per-peer per-tick property flush
    //
    // One set/reset frame per dirty property; the frames are a few bytes each
    // so per-object packing buys little against the verb's simplicity.

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
    Array!ubyte _buf;

    void begin_frame(Verb verb)
    {
        _buf.clear();
        _buf ~= verb;
    }

    int send_frame(SyncPeer peer, TxQueue queue = TxQueue.control)
    {
        int r = peer.transmit_frame(_buf[], false, queue);
        if (r < 0)
        {
            // event-driven encodes (state/cmd/result/error/sub/...) have no retry path!!
            // a drop here means the peer permanently misses this event.
            log.warning("dropped frame to peer (", _buf.length, "B): verb=", enum_key_name!Verb(cast(Verb)_buf[0]));
        }
        return r;
    }
}


private:

import urt.meta.enuminfo : enum_key_from_value;

// constraint scalars are typed by their format; read stride bytes like compare_scalar does
Variant scalar_variant(ref const Scalar s, ValueType t)
{
    final switch (t) with (ValueType)
    {
        case bool_: return Variant(*cast(const(bool)*)s.raw.ptr);
        case u8:    return Variant(*cast(const(ubyte)*)s.raw.ptr);
        case s8:    return Variant(*cast(const(byte)*)s.raw.ptr);
        case u16:   return Variant(*cast(const(ushort)*)s.raw.ptr);
        case s16:   return Variant(*cast(const(short)*)s.raw.ptr);
        case u32:   return Variant(*cast(const(uint)*)s.raw.ptr);
        case s32:   return Variant(*cast(const(int)*)s.raw.ptr);
        case u64:   return Variant(*cast(const(ulong)*)s.raw.ptr);
        case s64:   return Variant(*cast(const(long)*)s.raw.ptr);
        case f32:   return Variant(*cast(const(float)*)s.raw.ptr);
        case f64:   return Variant(*cast(const(double)*)s.raw.ptr);
        case char_:
        case user:  assert(false, "constraint on non-numeric type");
    }
}

alias enum_key_name = enum_key_from_value;

// Variant codec: tag byte + payload. Values the codec doesn't model natively
// travel as their string form (tag str), matching the JSON channel's fidelity.
enum Tag : ubyte
{
    nil,
    false_,
    true_,
    uint_,     // varint
    int_,      // zigzag varint (negative values)
    f64,       // 8 bytes LE
    str,       // varint length + bytes
    arr,       // varint count + elements
    map,       // varint count + (str key, value) pairs
}

void put_varint(ref Array!ubyte buf, ulong v)
{
    while (v >= 0x80)
    {
        buf ~= cast(ubyte)(v | 0x80);
        v >>= 7;
    }
    buf ~= cast(ubyte)v;
}

void put_zigzag(ref Array!ubyte buf, long v)
    => buf.put_varint((ulong(v) << 1) ^ ulong(v >> 63));

void put_f64(ref Array!ubyte buf, double d)
{
    ubyte[8] bytes = *cast(const(ubyte[8])*)&d;
    buf ~= bytes[];
}

void put_str(ref Array!ubyte buf, const(char)[] s)
{
    buf.put_varint(s.length);
    buf ~= cast(const(ubyte)[])s;
}

void put_variant(ref Array!ubyte buf, ref const Variant v)
{
    if (v.isNull)
        buf ~= Tag.nil;
    else if (v.isBool)
        buf ~= v.asBool ? Tag.true_ : Tag.false_;
    else if (v.isString)
    {
        buf ~= Tag.str;
        buf.put_str(v.asString());
    }
    else if (v.isArray)
    {
        buf ~= Tag.arr;
        buf.put_varint(v.length());
        foreach (i; 0 .. v.length())
            buf.put_variant(v[i]);
    }
    else if (v.isObject)
    {
        size_t count = 0;
        foreach (k, ref m; v)
            ++count;
        buf ~= Tag.map;
        buf.put_varint(count);
        foreach (k, ref m; v)
        {
            buf.put_str(k);
            buf.put_variant(m);
        }
    }
    else if (v.isNumber && !v.is_enum && !v.isQuantity)
    {
        if (v.isDouble)
        {
            buf ~= Tag.f64;
            buf.put_f64(v.asDouble);
        }
        else if (v.isUlong && v.asUlong > long.max)
        {
            buf ~= Tag.uint_;
            buf.put_varint(v.asUlong);
        }
        else if (v.asLong < 0)
        {
            buf ~= Tag.int_;
            buf.put_zigzag(v.asLong);
        }
        else
        {
            buf ~= Tag.uint_;
            buf.put_varint(v.asLong);
        }
    }
    else
    {
        // quantities, enums, user types: string form; receivers parse
        buf ~= Tag.str;
        ptrdiff_t len = v.toString(null, null, null);
        if (len <= 0)
        {
            buf.put_str(null);
            return;
        }
        buf.put_varint(len);
        v.toString(cast(char[])buf.extend(len), null, null);
    }
}

struct Reader
{
nothrow @nogc:

    const(ubyte)[] buf;
    size_t pos;
    bool fail;

    bool more() const pure
        => pos < buf.length;

    ubyte u8()
    {
        if (pos >= buf.length)
        {
            fail = true;
            return 0;
        }
        return buf[pos++];
    }

    ulong varint()
    {
        ulong v = 0;
        uint shift = 0;
        for (;;)
        {
            ubyte b = u8();
            if (fail)
                return 0;
            v |= ulong(b & 0x7F) << shift;
            if (!(b & 0x80))
                return v;
            shift += 7;
            if (shift >= 64)
            {
                fail = true;
                return 0;
            }
        }
    }

    long zigzag()
    {
        ulong v = varint();
        return long(v >> 1) ^ -long(v & 1);
    }

    double f64()
    {
        if (pos + 8 > buf.length)
        {
            fail = true;
            return 0;
        }
        double d = *cast(const(double)*)(buf.ptr + pos);
        pos += 8;
        return d;
    }

    const(char)[] str()
    {
        size_t n = cast(size_t)varint();
        if (fail || pos + n > buf.length)
        {
            fail = true;
            return null;
        }
        const(char)[] s = cast(const(char)[])buf[pos .. pos + n];
        pos += n;
        return s;
    }

    // depth-limited: a hostile frame can't recurse the stack away
    Variant variant(uint depth = 0)
    {
        enum max_depth = 16;
        if (depth > max_depth)
        {
            fail = true;
            return Variant();
        }

        ubyte tag = u8();
        if (fail || tag > Tag.max)
        {
            fail = true;
            return Variant();
        }
        final switch (cast(Tag)tag) with (Tag)
        {
            case nil:
                return Variant();
            case false_:
                return Variant(false);
            case true_:
                return Variant(true);
            case uint_:
            {
                ulong v = varint();
                return v <= long.max ? Variant(long(v)) : Variant(v);
            }
            case int_:
                return Variant(zigzag());
            case f64:
                return Variant(this.f64());
            case str:
                return Variant(this.str());
            case arr:
            {
                size_t count = cast(size_t)varint();
                if (fail || count > buf.length - pos)
                {
                    fail = true;
                    return Variant();
                }
                Variant a;
                foreach (i; 0 .. count)
                {
                    Variant e = variant(depth + 1);
                    if (fail)
                        return Variant();
                    a.asArray ~= e.move;
                }
                return a.move;
            }
            case map:
            {
                size_t count = cast(size_t)varint();
                if (fail || count > buf.length - pos)
                {
                    fail = true;
                    return Variant();
                }
                Variant m;
                foreach (i; 0 .. count)
                {
                    const(char)[] key = this.str();
                    Variant e = variant(depth + 1);
                    if (fail)
                        return Variant();
                    m.insert(key, e.move);
                }
                return m.move;
            }
        }
    }
}


unittest
{
    Array!ubyte buf;

    // varint + zigzag round-trip across the value range
    foreach (ulong v; [ulong(0), 1, 127, 128, 300, 0xFFFF, 0xFFFF_FFFF, ulong.max])
    {
        buf.clear();
        buf.put_varint(v);
        Reader r = Reader(buf[]);
        assert(r.varint() == v && !r.fail);
    }
    foreach (long v; [long(0), -1, 1, -64, 63, long.min, long.max])
    {
        buf.clear();
        buf.put_zigzag(v);
        Reader r = Reader(buf[]);
        assert(r.zigzag() == v && !r.fail);
    }

    // variant round-trip: scalars, strings, nesting
    // (values avoid the literals 0/1, which D converts to bool, selecting Variant's bool ctor)
    Variant v;
    v.asArray ~= Variant(42);
    v.asArray ~= Variant(-7);
    v.asArray ~= Variant(101.5);
    v.asArray ~= Variant("hello");
    v.asArray ~= Variant(true);
    Variant m;
    m.insert("a", Variant(5));
    m.insert("b", Variant("two"));
    v.asArray ~= m.move;

    buf.clear();
    buf.put_variant(v);
    Reader r = Reader(buf[]);
    Variant o = r.variant();
    assert(!r.fail);
    assert(o.length == 6);
    assert(o[0].asLong == 42);
    assert(o[1].asLong == -7);
    assert(o[2].asDouble == 101.5);
    assert(o[3].asString == "hello");
    assert(o[4].isTrue);
    assert(o[5]["a"].asLong == 5);
    assert(o[5]["b"].asString == "two");

    // truncation must fail, not crash
    Reader t = Reader(buf[0 .. 3]);
    t.variant();
    assert(t.fail);

    Reader old_add = Reader(null);
    ulong peer_id = old_add.more ? old_add.varint() : 0;
    assert(peer_id == 0 && !old_add.fail);

    buf.clear();
    buf.put_varint(0x0123_4567_89AB_CDEF);
    Reader scoped_add = Reader(buf[]);
    peer_id = scoped_add.more ? scoped_add.varint() : 0;
    assert(peer_id == 0x0123_4567_89AB_CDEF && !scoped_add.fail);
}
