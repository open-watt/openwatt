module manager.sync;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.mem.string;
import urt.meta : AliasSeq;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.result;
import urt.string;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.console.command : CommandState, CommandCompletionState;
import manager.console.session;
import manager.plugin;

//version = DebugSyncChannel;

nothrow @nogc:


enum SyncMessageKind : ubyte
{
    bind,       // peer: proxy my authoritative object (target, type, props)
    unbind,     // peer: drop your proxy of my object (target)
    create,     // peer: instantiate an authoritative object (seq, type, props) -> bind{seq, target,...} on success, error{seq} on failure
    destroy,    // peer: my object is gone; drop any proxy (target)
    set,        // target.prop = value; optional seq for error correlation
    reset,      // target resets prop to peer's local default; optional seq for error correlation
    state,      // signal - target went online/offline/destroyed
    cmd,        // text - run console command, expect result
    result,     // text - result body for the matching seq
    sub,        // pattern - auto-bind matching objects as they appear
    unsub,      // pattern - stop auto-binding
    error,      // seq + text - rejection/error correlated to a prior seq
    enum_req,   // request enum metadata by `type` name, expect enum{seq}
    enum_,  // enum metadata - `type` is the enum name, `value` is an object map of member->value
    // TODO: element_update.
}

struct SyncProperty
{
    @disable this(this);
    String name;
    Variant value;
}

struct SyncMessage
{
    @disable this(this);
    SyncMessageKind kind;
    CID target;
    String type;            // for create / bind - concrete subtype (e.g. "tcp", "serial")
                            // for enum_req / enum - the enum type name
    String prop;            // for set / reset
    Variant value;          // for set; for enum - object map of member->value;
                            // for result - the command's return Variant
    StateSignal signal;     // for state
    String text;            // for cmd - command text; for result - captured output;
                            // for error - error message
    uint seq;               // correlation for cmd/result, bind/create/error, enum_req/enum, set/reset (error only)
    String pattern;         // for sub / unsub
    Array!SyncProperty props; // for create - currently-set properties; for bind - desired props
}


abstract class SyncChannel : ActiveObject
{
    alias Properties = AliasSeq!();
nothrow @nogc:

    enum type_name = "channel";
    enum collection_id = CollectionType.sync_channel;
    enum syncable = false;

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(type_info, id, flags);
    }

    abstract void send(ref const SyncMessage msg);

    override void rekey(CID old_id, CID new_id)
    {
        super.rekey(old_id, new_id);

        import urt.conv : parse_uint;
        import urt.string.format : tformat;

        foreach (i; 0 .. _patterns.length)
        {
            auto p = _patterns[i][];
            if (p.length == 0)
                continue;
            char prefix = p[0];
            if (prefix != '#' && prefix != '$')
                continue;
            uint base = prefix == '#' ? 10 : 16;
            auto digits = p[1 .. $];
            if (digits.length == 0)
                continue;
            size_t taken;
            ulong val = parse_uint(digits, &taken, base);
            if (taken != digits.length || val > uint.max)
                continue;
            if (cast(uint)val != old_id.raw)
                continue;

            const(char)[] rewritten = prefix == '#'
                ? tformat("#{0}", new_id.raw)
                : tformat("${0,X}", new_id.raw);
            ref slot = _patterns[i];
            slot = rewritten.makeString(g_app.allocator);
        }
    }

    void attach(BaseObject obj, uint seq = 0)
    {
        foreach (o; _attached)
            if (o is obj)
                return;

        ushort slot = sync_state_alloc(this);
        sync_state(slot).next = obj._sync_slot;
        obj._sync_slot = slot;
        _attached ~= obj;

        if (!obj._is_remote)
        {
            SyncMessage bind_msg;
            bind_msg.kind = SyncMessageKind.bind;
            bind_msg.target = obj.id;
            bind_msg.type = obj.type.addString();
            bind_msg.seq = seq;
            snapshot_props(obj, bind_msg.props);
            send(bind_msg);
        }

        if (auto ao = cast(ActiveObject)obj)
        {
            ao.subscribe(&on_obj_state_signal);
            if (!obj._is_remote && ao.running)
            {
                SyncMessage state_msg;
                state_msg.kind = SyncMessageKind.state;
                state_msg.target = obj.id;
                state_msg.signal = StateSignal.online;
                send(state_msg);
            }
        }
    }

    void detach(BaseObject obj)
    {
        foreach (i, o; _attached)
        {
            if (o is obj)
            {
                // walk the chain to find our slot, unlinking as we go.
                ushort target = sync_slot_none;
                if (obj._sync_slot != sync_slot_none &&
                    sync_state(obj._sync_slot).channel is this)
                {
                    target = obj._sync_slot;
                    obj._sync_slot = sync_state(target).next;
                }
                else
                {
                    ushort prev = obj._sync_slot;
                    while (prev != sync_slot_none)
                    {
                        ref prev_ss = sync_state(prev);
                        if (prev_ss.next != sync_slot_none &&
                            sync_state(prev_ss.next).channel is this)
                        {
                            target = prev_ss.next;
                            prev_ss.next = sync_state(target).next;
                            break;
                        }
                        prev = prev_ss.next;
                    }
                }

                if (auto ao = cast(ActiveObject)obj)
                    ao.unsubscribe(&on_obj_state_signal);

                if (target != sync_slot_none)
                    sync_state_free(target);
                _attached.remove(i);
                return;
            }
        }
    }

    void push_all_dirty()
    {
        foreach (obj; _attached)
        {
            if (obj._is_remote)
                continue;   // proxies don't originate property changes
            ushort slot = find_slot(obj);
            if (slot == sync_slot_none)
                continue;
            ref ss = sync_state(slot);
            if (!ss.props_dirty)
                continue;
            ulong dirty = ss.props_dirty;
            ulong set_bits = dirty & obj._props_set;
            ulong reset_bits = dirty & ~obj._props_set;
            foreach (i, p; obj.properties())
            {
                debug assert(i < 64, "only supports up to 64 properties!");
                ulong mask = ulong(1) << i;
                if (set_bits & mask)
                {
                    if (!p.get)
                        continue;
                    SyncMessage msg;
                    msg.kind = SyncMessageKind.set;
                    msg.target = obj.id;
                    msg.prop = p.name;
                    msg.value = p.get(obj);
                    send(msg);
                }
                else if (reset_bits & mask)
                {
                    SyncMessage msg;
                    msg.kind = SyncMessageKind.reset;
                    msg.target = obj.id;
                    msg.prop = p.name;
                    send(msg);
                }
            }
            ss.props_dirty &= ~dirty;
        }
    }

    void subscribe(String pattern)
    {
        foreach (ref p; _patterns)
            if (p[] == pattern[])
            {
                debug version (DebugSyncChannel)
                    log.info("sub: dedup hit for ", pattern[]);
                return;
            }

        _patterns ~= pattern.move;

        SyncChannel self = this;
        uint matched = 0, attached_count = 0;
        foreach_object((BaseObject obj) nothrow @nogc {
            if (!obj._typeInfo.syncable)
                return;
            if (!self.matches_any_pattern(obj))
                return;
            ++matched;
            size_t before = self._attached.length;
            self.attach(obj);
            if (self._attached.length > before)
                ++attached_count;
        });
        debug version (DebugSyncChannel)
            log.info("sub: walked, matched=", matched, " newly_attached=", attached_count,
                     " total_attached=", _attached.length);
    }

    void unsubscribe(scope const(char)[] pattern)
    {
        bool removed = false;
        foreach (i, ref p; _patterns)
        {
            if (p[] == pattern)
            {
                _patterns.remove(i);
                removed = true;
                break;
            }
        }
        if (!removed)
            return;

        for (ptrdiff_t i = cast(ptrdiff_t)_attached.length - 1; i >= 0; --i)
        {
            BaseObject obj = _attached[i];
            if (!matches_any_pattern(obj))
                detach(obj);
        }
    }

    final void on_object_created(BaseObject obj) nothrow @nogc
    {
        if (!obj._typeInfo.syncable)
            return;
        if (matches_any_pattern(obj))
            attach(obj);
    }

    const(String)[] subscriptions() const pure nothrow @nogc
        => _patterns[];

    uint request_enum(String name, ResultCallback cb = null)
    {
        uint seq = alloc_seq();
        if (cb)
            _pending_requests ~= PendingRequest(seq, PendingKind.enum_req, cb);
        SyncMessage msg;
        msg.kind = SyncMessageKind.enum_req;
        msg.type = name.move;
        msg.seq = seq;
        send(msg);
        return seq;
    }

    // Callback signature for async request responses.
    //   ok == true  : success; `value` is kind-specific (cmd result, enum map,
    //                 empty for create/set/reset); `text` is kind-specific
    //                 (cmd captured output, otherwise empty).
    //   ok == false : error; `value` is empty; `text` is the error message.
    //
    // For set/reset the callback only ever fires on error — successful
    // application is visible via the dirty-echo that carries the post-apply
    // value.
    alias ResultCallback = void delegate(uint seq, bool ok, ref const Variant value, const(char)[] text) nothrow @nogc;

    uint request_cmd(const(char)[] text, ResultCallback cb = null)
    {
        uint seq = alloc_seq();
        if (cb)
            _pending_requests ~= PendingRequest(seq, PendingKind.cmd, cb);
        SyncMessage msg;
        msg.kind = SyncMessageKind.cmd;
        msg.seq = seq;
        msg.text = text.makeString(g_app.allocator);
        send(msg);
        return seq;
    }

    uint request_set(CID target, String prop, ref const Variant value, ResultCallback cb = null)
    {
        uint seq = alloc_seq();
        if (cb)
            _pending_requests ~= PendingRequest(seq, PendingKind.set, cb);
        SyncMessage msg;
        msg.kind = SyncMessageKind.set;
        msg.target = target;
        msg.prop = prop.move;
        msg.value = value;
        msg.seq = seq;
        send(msg);
        return seq;
    }

    uint request_reset(CID target, String prop, ResultCallback cb = null)
    {
        uint seq = alloc_seq();
        if (cb)
            _pending_requests ~= PendingRequest(seq, PendingKind.reset, cb);
        SyncMessage msg;
        msg.kind = SyncMessageKind.reset;
        msg.target = target;
        msg.prop = prop.move;
        msg.seq = seq;
        send(msg);
        return seq;
    }

protected:

    final void apply_inbound(ref const SyncMessage msg)
    {

        // Channel-level messages - no attached object lookup required.
        final switch (msg.kind)
        {
            case SyncMessageKind.cmd:
                debug version (DebugSyncChannel)
                    log.info("recv cmd seq=", msg.seq, " text=", msg.text[]);
                handle_inbound_cmd(msg);
                return;
            case SyncMessageKind.result:
                debug version (DebugSyncChannel)
                    log.info("recv result seq=", msg.seq, " text=", msg.text[]);
                handle_cmd_result(msg);
                return;
            case SyncMessageKind.sub:
                debug version (DebugSyncChannel)
                    log.info("recv sub pattern=", msg.pattern[]);
                String p = msg.pattern;
                subscribe(p.move);
                return;
            case SyncMessageKind.unsub:
                debug version (DebugSyncChannel)
                    log.info("recv unsub pattern=", msg.pattern[]);
                unsubscribe(msg.pattern[]);
                return;
            case SyncMessageKind.bind:
                debug version (DebugSyncChannel)
                    log.info("recv bind target=", get_id(msg.target)[], " type=", msg.type[],
                             " seq=", msg.seq, " props=", msg.props.length);
                handle_inbound_bind(msg);
                return;
            case SyncMessageKind.create:
                debug version (DebugSyncChannel)
                    log.info("recv create seq=", msg.seq, " type=", msg.type[],
                             " props=", msg.props.length);
                handle_inbound_create(msg);
                return;
            case SyncMessageKind.error:
                debug version (DebugSyncChannel)
                    log.info("recv error seq=", msg.seq, " text=", msg.text[]);
                handle_error(msg);
                return;
            case SyncMessageKind.enum_req:
                debug version (DebugSyncChannel)
                    log.info("recv enum_req name=", msg.type[], " seq=", msg.seq);
                handle_inbound_enum_req(msg);
                return;
            case SyncMessageKind.enum_:
                debug version (DebugSyncChannel)
                    log.info("recv enum name=", msg.type[], " seq=", msg.seq);
                handle_enum_info(msg);
                return;
            case SyncMessageKind.unbind:
            case SyncMessageKind.destroy:
            case SyncMessageKind.set:
            case SyncMessageKind.reset:
            case SyncMessageKind.state:
                break;   // fall through to per-object dispatch below
        }

        foreach (obj; _attached)
        {
            if (obj.id == msg.target)
            {
                final switch (msg.kind)
                {
                    case SyncMessageKind.set:
                        Variant v = msg.value;
                        debug version (DebugSyncChannel)
                            log.info("recv set target=", get_id(msg.target)[],
                                     " prop=", msg.prop[], " value=", v);
                        StringResult rset = obj.sync_apply(msg.prop[], v);
                        // Only authoritative side reports errors and emits
                        // correlated echoes - proxies just mirror.
                        if (!obj._is_remote && msg.seq != 0)
                        {
                            if (rset.failed)
                                send_error(msg.seq, rset.message);
                            else
                                emit_response_echo(obj, msg.kind, msg.prop[], msg.seq);
                        }
                        break;
                    case SyncMessageKind.reset:
                        debug version (DebugSyncChannel)
                            log.info("recv reset target=", get_id(msg.target)[],
                                     " prop=", msg.prop[]);
                        StringResult rreset = obj.sync_reset(msg.prop[]);
                        if (!obj._is_remote && msg.seq != 0)
                        {
                            if (rreset.failed)
                                send_error(msg.seq, rreset.message);
                            else
                                emit_response_echo(obj, msg.kind, msg.prop[], msg.seq);
                        }
                        break;
                    case SyncMessageKind.state:
                        debug version (DebugSyncChannel)
                            log.info("recv state target=", get_id(msg.target)[],
                                     " signal=", msg.signal);
                        // destroyed shouldn't arrive via state (peer should send
                        // destroy instead), but handle it defensively.
                        if (auto ao = cast(ActiveObject)obj)
                             ao.set_remote_state(msg.signal);
                        break;
                    case SyncMessageKind.destroy:
                        // Request to destroy an authoritative object.
                        debug version (DebugSyncChannel)
                            log.info("recv destroy target=", get_id(msg.target)[]);
                        if (obj._is_remote)
                        {
                            // We hold a proxy, not the real object. Non-hub mode:
                            // fail. Hub forwarding deferred.
                            send_error(msg.seq, "not my object");
                            return;
                        }
                        detach(obj);   // stop our outbound emission before destroy fires
                        obj.destroy();
                        // Confirm destruction back to the requester (informational).
                        {
                            SyncMessage ub;
                            ub.kind = SyncMessageKind.unbind;
                            ub.target = msg.target;
                            ub.seq = msg.seq;
                            send(ub);
                        }
                        break;
                    case SyncMessageKind.unbind:
                        // Peer's authoritative object is gone; drop our proxy.
                        debug version (DebugSyncChannel)
                            log.info("recv unbind target=", get_id(msg.target)[]);
                        if (!obj._is_remote)
                        {
                            debug version (DebugSyncChannel)
                                log.warning("unbind targets a local auth object; ignoring");
                            break;
                        }
                        detach(obj);
                        obj.destroy();
                        break;
                    case SyncMessageKind.bind:
                    case SyncMessageKind.create:
                    case SyncMessageKind.cmd:
                    case SyncMessageKind.result:
                    case SyncMessageKind.sub:
                    case SyncMessageKind.unsub:
                    case SyncMessageKind.error:
                    case SyncMessageKind.enum_req:
                    case SyncMessageKind.enum_:
                        assert(false);   // handled above
                }
                return;
            }
        }
        debug version (DebugSyncChannel)
            log.warning("recv: no attached target for ", get_id(msg.target)[]);
    }

    void handle_inbound_cmd(ref const SyncMessage msg)
    {
        StringSession session = g_app.console.createSession!StringSession();
        Variant result;
        CommandState cmd = g_app.console.execute(session, msg.text[], result);
        if (cmd is null)
        {
            send_cmd_result(msg.seq, result, session.takeOutput()[]);
            g_app.console.destroy_session(session);
            return;
        }
        _pending_inbound_cmds ~= PendingInboundCmd(msg.seq, session, cmd);
    }

    void handle_cmd_result(ref const SyncMessage msg)
    {
        if (!resolve_pending(msg.seq, PendingKind.cmd, true, msg.value, msg.text[]))
        {
            debug version (DebugSyncChannel)
                log.warning("result for unknown seq=", msg.seq);
        }
    }

    void handle_error(ref const SyncMessage msg)
    {
        Variant empty;
        if (!resolve_pending(msg.seq, PendingKind.any, false, empty, msg.text[]))
        {
            debug version (DebugSyncChannel)
                log.warning("error for unknown seq=", msg.seq);
        }
    }

    final bool resolve_pending(uint seq, PendingKind expect, bool ok, ref const Variant value, const(char)[] text)
    {
        foreach (i, ref w; _pending_requests)
        {
            if (w.seq != seq)
                continue;
            if (expect != PendingKind.any && w.kind != expect)
            {
                debug version (DebugSyncChannel)
                    log.warning("pending seq=", seq, " kind mismatch: expected ",
                                expect, " got ", w.kind);
                return false;
            }
            if (w.cb)
                w.cb(seq, ok, value, text);
            _pending_requests.remove(i);
            return true;
        }
        return false;
    }

    final uint alloc_seq() nothrow @nogc
    {
        uint seq = ++_next_seq;
        if (seq == 0)
            seq = ++_next_seq;   // skip reserved zero on wrap
        return seq;
    }

    final void drain_pending_inbound_cmds()
    {
        size_t i = 0;
        while (i < _pending_inbound_cmds.length)
        {
            ref PendingInboundCmd req = _pending_inbound_cmds[i];
            if (req.command.update() == CommandCompletionState.in_progress)
            {
                ++i;
                continue;
            }
            send_cmd_result(req.seq, req.command.result, req.session.takeOutput()[]);
            g_app.console.destroy_session(req.session);
            _pending_inbound_cmds.remove(i);
        }
    }

    final void send_cmd_result(uint seq, ref const Variant value, const(char)[] output)
    {
        SyncMessage msg;
        msg.kind = SyncMessageKind.result;
        msg.seq = seq;
        msg.value = value;
        msg.text = output.makeString(g_app.allocator);
        send(msg);
    }

    void handle_inbound_bind(ref const SyncMessage msg)
    {
        auto rt = msg.type[] in g_app.types;
        if (!rt)
        {
            debug version (DebugSyncChannel)
                log.warning("bind: unknown type '", msg.type[], "'");
            return;
        }
        const(CollectionTypeInfo)* ti = rt.type_info;
        if (ti.is_abstract)
            return;

        const(char)[] name = find_prop_string(msg, "name");
        if (!name.length)
        {
            debug version (DebugSyncChannel)
                log.warning("bind: no name property");
            return;
        }

        BaseCollection collection = BaseCollection(ti);
        BaseObject obj = collection.create(name, ObjectFlags.remote);
        if (!obj)
        {
            debug version (DebugSyncChannel)
                log.warning("bind: create returned null for name '", name, "'");
            return;
        }

        if (obj.id != msg.target)
        {
            debug version (DebugSyncChannel)
                log.warning("bind: local CID ", obj.id.raw, " != peer CID ",
                            msg.target.raw, " (rekey not yet implemented)");
        }

        apply_props(obj, msg);
        attach(obj);

        if (msg.seq != 0)
        {
            Variant empty;
            resolve_pending(msg.seq, PendingKind.create, true, empty, null);
        }
    }

    void handle_inbound_create(ref const SyncMessage msg)
    {
        auto rt = msg.type[] in g_app.types;
        if (!rt)
        {
            send_error(msg.seq, "unknown type");
            return;
        }
        const(CollectionTypeInfo)* ti = rt.type_info;
        if (ti.is_abstract)
        {
            send_error(msg.seq, "abstract type");
            return;
        }

        const(char)[] name = find_prop_string(msg, "name");
        if (!name.length)
        {
            send_error(msg.seq, "name required");
            return;
        }

        BaseCollection collection = BaseCollection(ti);
        BaseObject obj = collection.create(name, ObjectFlags.none);
        if (!obj)
        {
            send_error(msg.seq, "create failed");
            return;
        }

        apply_props(obj, msg);
        attach(obj, msg.seq);
    }

    final void emit_response_echo(BaseObject obj, SyncMessageKind kind, scope const(char)[] prop_name, uint seq) nothrow @nogc
    {
        ulong prop_mask = 0;
        size_t prop_index = size_t.max;
        foreach (i, p; obj.properties())
        {
            if (p.name[] == prop_name)
            {
                prop_index = i;
                prop_mask = ulong(1) << i;
                break;
            }
        }

        SyncMessage msg;
        msg.kind = kind;
        msg.target = obj.id;
        msg.prop = prop_name.addString();
        msg.seq = seq;
        if (kind == SyncMessageKind.set && prop_index != size_t.max)
        {
            auto p = obj.properties()[prop_index];
            if (p.get)
                msg.value = p.get(obj);
        }
        send(msg);

        if (prop_mask)
        {
            ushort slot = find_slot(obj);
            if (slot != sync_slot_none)
                sync_state(slot).props_dirty &= ~prop_mask;
        }
    }

    void send_error(uint seq, const(char)[] text) nothrow @nogc
    {
        SyncMessage msg;
        msg.kind = SyncMessageKind.error;
        msg.seq = seq;
        msg.text = text.addString();
        send(msg);
    }

    static const(char)[] find_prop_string(ref const SyncMessage msg, const(char)[] name) nothrow @nogc
    {
        foreach (ref kv; msg.props)
            if (kv.name[] == name)
                return kv.value.asString();
        return null;
    }

    static void apply_props(BaseObject obj, ref const SyncMessage msg) nothrow @nogc
    {
        foreach (ref kv; msg.props)
        {
            if (kv.name[] == "name" || kv.name[] == "type")
                continue;
            Variant v = kv.value;
            obj.set(kv.name[], v);
        }
    }

    static void snapshot_props(BaseObject obj, ref Array!SyncProperty out_props) nothrow @nogc
    {
        ulong set_bits = obj._props_set;
        foreach (i, p; obj.properties())
        {
            debug assert(i < 64, "only supports up to 64 properties!");
            if (!(set_bits & (ulong(1) << i)))
                continue;
            if (!p.get)
                continue;
            if (p.name[] == "type")
                continue;
            SyncProperty kv;
            kv.name = p.name;
            kv.value = p.get(obj);
            out_props ~= kv.move;
        }
    }

    void handle_inbound_enum_req(ref const SyncMessage msg)
    {
        auto pe = msg.type[] in g_app.enum_templates;
        if (!pe)
        {
            send_error(msg.seq, "unknown enum");
            return;
        }

        SyncMessage resp;
        resp.kind = SyncMessageKind.enum_;
        resp.type = msg.type;
        resp.seq = msg.seq;
        const(VoidEnumInfo)* e = *pe;
        foreach (i; 0 .. e.count)
        {
            const(char)[] key = e.key_by_decl_index(i);
            resp.value.insert(key, e.value_for(key));
        }
        send(resp);
    }

    void handle_enum_info(ref const SyncMessage msg)
    {
        if (msg.seq != 0)
            resolve_pending(msg.seq, PendingKind.enum_req, true, msg.value, null);
    }

private:

    enum PendingKind : ubyte
    {
        any,    // wildcard match used only by handle_error
        cmd,
        create,
        enum_req,
        set,
        reset,
    }

    struct PendingInboundCmd
    {
        uint seq;
        StringSession session;
        CommandState command;
    }

    struct PendingRequest
    {
        uint seq;
        PendingKind kind;
        ResultCallback cb;
    }

    Array!BaseObject _attached;
    Array!String _patterns;

    Array!PendingInboundCmd _pending_inbound_cmds;
    Array!PendingRequest _pending_requests;

    uint _next_seq;

    ushort find_slot(BaseObject obj) nothrow @nogc
    {
        for (ushort slot = obj._sync_slot; slot != sync_slot_none; )
        {
            ref ss = sync_state(slot);
            if (ss.channel is this)
                return slot;
            slot = ss.next;
        }
        return sync_slot_none;
    }

    package final void detach_all() nothrow @nogc
    {
        Array!BaseObject proxies;
        foreach (o; _attached)
            if (o._is_remote)
                proxies ~= o;

        while (_attached.length)
            detach(_attached[0]);

        foreach (p; proxies)
            p.destroy();
    }

    // Pattern forms:
    //   "#<decimal>"          - exact CID match (decimal uint)
    //   "$<hex>"              - exact CID match (hex uint, case-insensitive)
    //   "[=]<type>:<name>"    - type/name match; both halves accept wildcards.
    //                           Without '=' the type half matches any ancestor.
    //     "modbus:goodwe_ems"  - any modbus (incl. subtypes) named goodwe_ems
    //     "=modbus:goodwe_ems" - only objects whose concrete type is exactly "modbus"
    //     "interface:*"        - everything derived from "interface"
    //     "*:*"                - everything
    bool matches_any_pattern(BaseObject obj) nothrow @nogc
    {
        const(char)[] name = obj.name[];
        foreach (ref p; _patterns)
            if (pattern_matches(p[], obj, name))
                return true;
        return false;
    }

    static bool pattern_matches(const(char)[] pattern, BaseObject obj, const(char)[] name) nothrow @nogc
    {
        import urt.conv : parse_uint;
        import urt.string : wildcard_match;

        if (pattern.length == 0)
            return false;

        // #<decimal> / $<hex> - exact CID match, no wildcards.
        if (pattern[0] == '#' || pattern[0] == '$')
        {
            uint base = pattern[0] == '#' ? 10 : 16;
            const(char)[] digits = pattern[1 .. $];
            if (digits.length == 0)
                return false;
            size_t taken;
            ulong val = parse_uint(digits, &taken, base);
            if (taken != digits.length || val > uint.max)
                return false;
            return obj.id.raw == cast(uint)val;
        }

        bool strict = false;
        if (pattern[0] == '=')
        {
            strict = true;
            pattern = pattern[1 .. $];
        }

        ptrdiff_t colon = -1;
        foreach (i, c; pattern)
        {
            if (c == ':')
            {
                colon = cast(ptrdiff_t)i;
                break;
            }
        }
        if (colon < 0)
            return false;   // malformed - require "type:name"

        const(char)[] type_pat = pattern[0 .. colon];
        const(char)[] name_pat = pattern[colon + 1 .. $];

        if (!wildcard_match(name_pat, name))
            return false;

        if (strict)
            return wildcard_match(type_pat, obj.type);

        // subtype-inclusive: any ancestor type may match
        for (const(CollectionTypeInfo)* ti = obj._typeInfo; ti !is null;
             ti = ti.get_super ? ti.get_super() : null)
        {
            if (wildcard_match(type_pat, ti.type[]))
                return true;
        }
        return false;
    }

    void on_obj_state_signal(ActiveObject obj, StateSignal signal) nothrow @nogc
    {
        // Proxies don't originate state changes; only authoritative side emits.
        if (obj._is_remote)
            return;

        if (signal == StateSignal.destroyed)
        {
            // Local authoritative object is gone - tell peers their proxies
            // are no longer valid (informational unbind), then sever our side.
            SyncMessage unbind_msg;
            unbind_msg.kind = SyncMessageKind.unbind;
            unbind_msg.target = obj.id;
            send(unbind_msg);
            detach(obj);
            return;
        }
        SyncMessage msg;
        msg.kind = SyncMessageKind.state;
        msg.target = obj.id;
        msg.signal = signal;
        send(msg);
    }
}


// =============================================================================
// LoopbackSyncChannel - test fixture.
// =============================================================================
//
// Outbound messages are captured in an in-memory queue for inspection;
// inbound messages can be injected directly via CLI.

class LoopbackSyncChannel : SyncChannel
{
    alias Properties = AliasSeq!();
nothrow @nogc:

    enum type_name = "loopback";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!LoopbackSyncChannel, id, flags);
    }

    override void send(ref const SyncMessage msg)
    {
        debug version (DebugSyncChannel)
        {
            final switch (msg.kind)
            {
                case SyncMessageKind.bind:
                    log.info("send bind target=", get_id(msg.target)[], " type=", msg.type[],
                             " seq=", msg.seq, " props=", msg.props.length);
                    break;
                case SyncMessageKind.unbind:
                    log.info("send unbind target=", get_id(msg.target)[]);
                    break;
                case SyncMessageKind.create:
                    log.info("send create seq=", msg.seq, " type=", msg.type[],
                             " props=", msg.props.length);
                    break;
                case SyncMessageKind.destroy:
                    log.info("send destroy target=", get_id(msg.target)[]);
                    break;
                case SyncMessageKind.set:
                    log.info("send set target=", get_id(msg.target)[],
                             " prop=", msg.prop[], " value=", msg.value);
                    break;
                case SyncMessageKind.reset:
                    log.info("send reset target=", get_id(msg.target)[],
                             " prop=", msg.prop[]);
                    break;
                case SyncMessageKind.state:
                    log.info("send state target=", get_id(msg.target)[],
                             " signal=", msg.signal);
                    break;
                case SyncMessageKind.cmd:
                    log.info("send cmd seq=", msg.seq, " text=", msg.text[]);
                    break;
                case SyncMessageKind.result:
                    log.info("send result seq=", msg.seq, " value=", msg.value, " text=", msg.text[]);
                    break;
                case SyncMessageKind.sub:
                    log.info("send sub pattern=", msg.pattern[]);
                    break;
                case SyncMessageKind.unsub:
                    log.info("send unsub pattern=", msg.pattern[]);
                    break;
                case SyncMessageKind.error:
                    log.info("send error seq=", msg.seq, " text=", msg.text[]);
                    break;
                case SyncMessageKind.enum_req:
                    log.info("send enum_req name=", msg.type[], " seq=", msg.seq);
                    break;
                case SyncMessageKind.enum_:
                    log.info("send enum name=", msg.type[], " seq=", msg.seq);
                    break;
            }
        }
        SyncMessage copy;
        copy.kind = msg.kind;
        copy.target = msg.target;
        copy.type = msg.type;
        copy.prop = msg.prop;
        copy.value = msg.value;
        copy.signal = msg.signal;
        copy.text = msg.text;
        copy.seq = msg.seq;
        copy.pattern = msg.pattern;
        copy.props.reserve(msg.props.length);
        foreach (ref kv; msg.props)
        {
            SyncProperty k;
            k.name = kv.name;
            k.value = kv.value;
            copy.props ~= k.move;
        }
        _outbound ~= copy.move;
    }

    // Test helper: apply a synthetic incoming message - as if from a peer.
    void inject(ref const SyncMessage msg)
    {
        apply_inbound(msg);
    }

    size_t outbound_count() const pure
        => _outbound.length;

    ref const(SyncMessage) outbound_at(size_t i) const pure
        => _outbound[i];

    void clear_outbound()
    {
        _outbound.clear();
    }

private:
    Array!SyncMessage _outbound;
}


// =============================================================================
// Module + CLI commands.
// =============================================================================

class SyncModule : Module
{
    mixin DeclareModule!"sync";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!LoopbackSyncChannel("/sync/channel/loopback");
        g_app.console.register_command!attach_cmd("/sync/channel/loopback", this, "attach");
        g_app.console.register_command!attach_all_cmd("/sync/channel/loopback", this, "attach-all");
        g_app.console.register_command!detach_cmd("/sync/channel/loopback", this, "detach");
        g_app.console.register_command!subscribe_cmd("/sync/channel/loopback", this, "subscribe");
        g_app.console.register_command!unsubscribe_cmd("/sync/channel/loopback", this, "unsubscribe");
        g_app.console.register_command!inject_cmd("/sync/channel/loopback", this, "inject");
        g_app.console.register_command!request_enum_cmd("/sync/channel/loopback", this, "request-enum");
        g_app.console.register_command!dump_cmd("/sync/channel/loopback", this, "dump");
        g_app.console.register_command!clear_cmd("/sync/channel/loopback", this, "clear");

        // Hook into Collection object-creation - auto-attach matching objects
        // to every channel's active subscriptions as they come into being.
        register_object_created_handler(&on_object_created_global);
    }

    override void update()
    {
        // Drain dirty changes from every attached object on every channel.
        // Polymorphic iteration over the SyncChannel collection picks up every
        // subclass (loopback today, TCP/WebSocket/shmem in future).
        foreach (ch; Collection!SyncChannel().values)
        {
            ch.push_all_dirty();
            ch.drain_pending_inbound_cmds();
        }
    }

    // Object lifecycle hook - notify every channel so its subscriptions can
    // auto-attach the new object if it matches.
    void on_object_created_global(BaseObject obj) nothrow @nogc
    {
        foreach (ch; Collection!SyncChannel().values)
            ch.on_object_created(obj);
    }

    void attach_cmd(Session session, LoopbackSyncChannel channel, BaseObject target)
    {
        if (!channel || !target)
        {
            session.write_line("attach: channel and target required");
            return;
        }
        channel.attach(target);
        session.write_line("attached ", target.name[], " to ", channel.name[]);
    }

    // Attaches every syncable object in every collection to this channel.
    void attach_all_cmd(Session session, LoopbackSyncChannel channel)
    {
        if (!channel)
            return;
        uint count = 0;
        auto ch = channel;
        foreach_object((BaseObject obj) nothrow @nogc {
            if (obj is ch)
                return;
            if (!obj._typeInfo.syncable)
                return;
            ch.attach(obj);
            ++count;
        });
        session.write_line("attached ", count, " objects to ", channel.name[]);
    }

    void detach_cmd(Session session, LoopbackSyncChannel channel, BaseObject target)
    {
        if (!channel || !target)
            return;
        channel.detach(target);
        session.write_line("detached ", target.name[], " from ", channel.name[]);
    }

    // /sync/channel/loopback/subscribe channel=<ch> pattern=<glob>
    // Example: pattern=/device/* - attaches every device and any future device.
    void subscribe_cmd(Session session, LoopbackSyncChannel channel, String pattern)
    {
        if (!channel || !pattern)
        {
            session.write_line("subscribe: channel and pattern required");
            return;
        }
        channel.subscribe(pattern.move);
        session.write_line("subscribed ", channel.name[], " to ", pattern[]);
    }

    void unsubscribe_cmd(Session session, LoopbackSyncChannel channel, const(char)[] pattern)
    {
        if (!channel || pattern.empty)
            return;
        channel.unsubscribe(pattern);
        session.write_line("unsubscribed ", channel.name[], " from ", pattern);
    }

    void request_enum_cmd(Session session, LoopbackSyncChannel channel, String name)
    {
        if (!channel || !name)
        {
            session.write_line("request-enum: channel and name required");
            return;
        }
        channel.request_enum(name.move);
    }

    void inject_cmd(Session session, LoopbackSyncChannel channel,
                    BaseObject target, const(char)[] property, Variant value)
    {
        if (!channel || !target)
        {
            session.write_line("inject: channel and target required");
            return;
        }
        SyncMessage msg;
        msg.kind = SyncMessageKind.set;
        msg.target = target.id;
        msg.prop = property.addString();
        msg.value = value;
        channel.inject(msg);
        session.write_line("injected ", property, "=", value, " on ", target.name[]);
    }

    void dump_cmd(Session session, LoopbackSyncChannel channel)
    {
        if (!channel)
            return;
        auto n = channel.outbound_count;
        session.write_line("outbound queue: ", n, " message(s)");
        foreach (i; 0 .. n)
        {
            const(SyncMessage)* m = &channel.outbound_at(i);
            final switch (m.kind)
            {
                case SyncMessageKind.bind:
                    session.write_line("  [", i, "] bind target=", get_id(m.target)[], " type=", m.type[],
                                       " seq=", m.seq, " props=", m.props.length);
                    foreach (ref kv; m.props)
                        session.write_line("      ", kv.name[], "=", kv.value);
                    break;
                case SyncMessageKind.unbind:
                    session.write_line("  [", i, "] unbind target=", get_id(m.target)[]);
                    break;
                case SyncMessageKind.create:
                    session.write_line("  [", i, "] create seq=", m.seq, " type=", m.type[],
                                       " props=", m.props.length);
                    foreach (ref kv; m.props)
                        session.write_line("      ", kv.name[], "=", kv.value);
                    break;
                case SyncMessageKind.destroy:
                    session.write_line("  [", i, "] destroy target=", get_id(m.target)[]);
                    break;
                case SyncMessageKind.set:
                    session.write_line("  [", i, "] set target=", get_id(m.target)[],
                                       " prop=", m.prop[], " value=", m.value);
                    break;
                case SyncMessageKind.reset:
                    session.write_line("  [", i, "] reset target=", get_id(m.target)[],
                                       " prop=", m.prop[]);
                    break;
                case SyncMessageKind.state:
                    session.write_line("  [", i, "] state target=", get_id(m.target)[],
                                       " signal=", m.signal);
                    break;
                case SyncMessageKind.cmd:
                    session.write_line("  [", i, "] cmd seq=", m.seq, " text=", m.text[]);
                    break;
                case SyncMessageKind.result:
                    session.write_line("  [", i, "] result seq=", m.seq, " value=", m.value, " text=", m.text[]);
                    break;
                case SyncMessageKind.sub:
                    session.write_line("  [", i, "] sub pattern=", m.pattern[]);
                    break;
                case SyncMessageKind.unsub:
                    session.write_line("  [", i, "] unsub pattern=", m.pattern[]);
                    break;
                case SyncMessageKind.error:
                    session.write_line("  [", i, "] error seq=", m.seq, " text=", m.text[]);
                    break;
                case SyncMessageKind.enum_req:
                    session.write_line("  [", i, "] enum_req name=", m.type[], " seq=", m.seq);
                    break;
                case SyncMessageKind.enum_:
                    session.write_line("  [", i, "] enum name=", m.type[], " seq=", m.seq);
                    if (m.value.isObject)
                    {
                        foreach (k, ref v; *cast(Variant*)&m.value)
                            session.write_line("      ", k, "=", v);
                    }
                    break;
            }
        }
    }

    void clear_cmd(Session session, LoopbackSyncChannel channel)
    {
        if (!channel)
            return;
        channel.clear_outbound();
    }
}
