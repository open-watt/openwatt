module protocol.obd;

import urt.array;
import urt.conv;
import urt.log;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.config : ConfItem;
import manager.device;
import manager.element;
import manager.plugin;
import manager.profile;
import manager.sample;
import manager.sample.spec : stream_be_context;
import manager.series;

import router.iface;
import router.iface.packet;

import protocol.obd.iface;

//version = DebugOBDBinding;

nothrow @nogc:


package __gshared uint obd_section_kind;

struct ElementDesc_OBD
{
    ubyte mode;
    ubyte pid_bytes;    // 1 for J1979 pids, 2 for mode 22 DIDs
    ushort pid;
    uint ecu;           // request arbitration id; 0 = functional broadcast
    ubyte offset;       // within the pid's data block
    ubyte length;
    ushort desc = 0xFFFF;
}

class OBDProtocolModule : Module, ProfileSections
{
    mixin DeclareModule!"protocol.obd";
nothrow @nogc:

    override void init()
    {
        register_packet_codec!OBDFrame();

        obd_section_kind = register_profile_section("obd", this);

        g_app.console.register_collection!OBDInterface();
        g_app.console.register_collection!OBDBinding();
    }

    uint element_size(uint)
        => cast(uint)ElementDesc_OBD.sizeof;

    void count_element(uint, ref const ConfItem, ref ProfileSize) {}

    bool parse_element(uint kind, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        import urt.log : writeWarning;

        const(char)[] tail = item.value;

        ElementDesc_OBD* obd = cast(ElementDesc_OBD*)slot.ptr;
        *obd = ElementDesc_OBD.init;

        const(char)[] mode = tail.split!',';
        const(char)[] pid = tail.split!',';
        const(char)[] offset = tail.split!',';
        const(char)[] type = tail.split!','.unQuote;
        const(char)[] units;

        // remaining fields: units column and/or ecu=<id>
        while (true)
        {
            const(char)[] field = tail.split!','.unQuote;
            if (field.empty)
                break;
            if (field.startsWith("ecu="))
            {
                size_t t;
                ulong id = field[4 .. $].parse_uint_with_base(&t);
                if (t != field.length - 4 || id > 0x1FFFFFFF)
                {
                    writeWarning("Invalid OBD ecu id: ", field);
                    return false;
                }
                obd.ecu = cast(uint)id;
            }
            else
                units = field;
        }

        size_t taken;
        ulong v = mode.parse_uint_with_base(&taken);
        if (taken != mode.length || v > 0x3F)
        {
            writeWarning("Invalid OBD mode: ", mode);
            return false;
        }
        obd.mode = cast(ubyte)v;
        obd.pid_bytes = obd.mode == 0x22 ? 2 : 1;

        v = pid.parse_uint_with_base(&taken);
        if (taken != pid.length || v > (obd.pid_bytes == 2 ? 0xFFFF : 0xFF))
        {
            writeWarning("Invalid OBD pid: ", pid);
            return false;
        }
        obd.pid = cast(ushort)v;

        v = offset.parse_uint_with_base(&taken);
        if (taken != offset.length || v > ubyte.max)
        {
            writeWarning("Invalid OBD data offset: ", offset);
            return false;
        }
        obd.offset = cast(ubyte)v;

        return b.compile_value(type, units, stream_be_context, obd.desc, obd.length);
    }
}


class OBDBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("profile", profile),
                                 Prop!("model", model));
nothrow @nogc:

    enum type_name = "obd-binding";
    enum path = "/binding/obd";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!OBDBinding, id, flags);
    }

    final inout(OBDInterface) iface() inout pure
        => _iface.get;
    final void iface(OBDInterface value)
    {
        if (_iface.get is value)
            return;
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&packet_handler);
            _subscribed = false;
        }
        _iface = value;
        mark_set!(typeof(this), "interface")();
        restart();
    }

    final ref const(String) profile() const pure
        => _profile_name;
    final void profile(String value)
    {
        if (value == _profile_name)
            return;
        _profile_name = value.move;
        mark_set!(typeof(this), "profile")();
        restart();
    }

    final ref const(String) model() const pure
        => _model_name;
    final void model(String value)
    {
        if (value == _model_name)
            return;
        _model_name = value.move;
        mark_set!(typeof(this), "model")();
        restart();
    }

    override const(char)[] status_message() const
    {
        if (running && _asleep)
            return "Vehicle not responding";
        return super.status_message();
    }

    final override bool validate() const pure
    {
        return _iface.get !is null && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup()
    {
        if (!materialise())
            return CompletionStatus.error;

        OBDInterface i = _iface.get;
        if (!i || !i.running)
            return CompletionStatus.continue_;

        i.subscribe(&packet_handler, PacketFilter(type: PacketType.obd, direction: PacketDirection.incoming));
        i.subscribe(&iface_state_change);
        _subscribed = true;

        begin_discovery();
        issue_requests();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _iface.unsubscribe(&iface_state_change);
            _iface.unsubscribe(&packet_handler);
            _subscribed = false;
        }
        if (!_dispatched && _dispatch_handle > 0)
            abort_dispatch(_dispatch_handle);
        _dispatch_handle = 0;
        _dispatched = false;
        disarm_poll();
        disarm_window();
        elements.clear();
        _outstanding = false;
        _asleep = false;
        _wake_discovery_pending = false;
        _misses = 0;
        return super.shutdown();
    }

protected:
    final override const(char)[] profile_name() const pure
        => _profile_name[];
    final override const(char)[] model_name() const pure
        => _model_name[];

    final override FormatId add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        if (desc.kind != obd_section_kind)
            return FormatId.invalid;
        ref const ElementDesc_OBD obd = _profile_data.get_section!ElementDesc_OBD(obd_section_kind, desc.element);
        if (obd.desc == 0xFFFF)
            return FormatId.invalid;

        SampleDesc sd = desc_by_index(obd.desc);
        const(DataFormat)* fmt = sd.fmt;
        e.format = sd.format;
        if (fmt.is_scalar)
        {
            Scalar z;
            z.raw[] = 0;
            e.value = box_record(z.raw.ptr, *fmt);
        }

        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.mode = obd.mode;
        se.pid_bytes = obd.pid_bytes;
        se.pid = obd.pid;
        se.ecu = obd.ecu;
        se.offset = obd.offset;
        se.length = obd.length;
        se.desc = sd;

        switch (desc.update_frequency)
        {
            case Frequency.realtime:  se.sampleTimeMs = 400;        break;
            case Frequency.high:      se.sampleTimeMs = 1_000;      break;
            case Frequency.medium:    se.sampleTimeMs = 10_000;     break;
            case Frequency.low:       se.sampleTimeMs = 60_000;     break;
            case Frequency.constant:  se.sampleTimeMs = 0;          break;
            case Frequency.on_demand: se.sampleTimeMs = ushort.max; break;
            default:                  se.sampleTimeMs = 10_000;     break;
        }

        return sd.format;
    }

    // transport and timer edges, overridable so tests can drive the scheduler
    int submit(uint ecu, bool extended, const(ubyte)[] request)
    {
        OBDInterface i = _iface.get;
        if (!i)
            return -1;
        Packet p;
        ref OBDFrame f = p.init!OBDFrame(request);
        f.src_id = 0;
        f.dst_id = ecu;
        f.extended = extended;
        return i.forward(p, &on_dispatch);
    }

    void abort_dispatch(int handle)
    {
        if (OBDInterface i = _iface.get)
            i.abort(handle);
    }

    void arm_window(Duration d)
    {
        g_app.cancel(&window_fired);
        g_app.schedule(getTime() + d, &window_fired);
    }

    void disarm_window()
    {
        g_app.cancel(&window_fired);
    }

    void arm_poll(MonoTime when)
    {
        g_app.cancel(&poll_timer_fired);
        g_app.schedule(when, &poll_timer_fired);
    }

    void disarm_poll()
    {
        g_app.cancel(&poll_timer_fired);
    }

private:

    // response timing is anchored at transport dispatch; the timeout must exceed the
    // adapter's own command lifecycle (ELM327: 3s response timeout) so the binding
    // never gives up on a request the transport is still committed to
    enum Duration request_timeout = 5.seconds;
    enum Duration submission_timeout = 30.seconds;
    enum Duration collection_window = 250.msecs;
    enum Duration retry_interval = 1.seconds;
    enum Duration probe_interval = 10.seconds;
    enum miss_threshold = 3;

    ObjectRef!OBDInterface _iface;
    String _profile_name;
    String _model_name;

    bool _subscribed;
    bool _outstanding;
    bool _dispatched;
    bool _asleep;
    bool _discovering;
    bool _wake_discovery_pending;
    int _dispatch_handle;
    ubyte _misses;
    ubyte _out_mode;
    ubyte _out_responses;
    ubyte _out_num_pids;
    uint _out_dst;
    ushort[6] _out_pids;
    ubyte _mask_page;
    ubyte _mask_pages_needed;
    uint[8] _mask;
    ubyte _mask_have;
    MonoTime _sent_time;

    Array!SampleElement elements;

    struct SampleElement
    {
        Element* element;
        MonoTime lastUpdate;
        ushort sampleTimeMs;
        ubyte flags; // 1 - in-flight, 2 - done (constant sampled or unsupported)
        ubyte mode;
        ubyte pid_bytes;
        ushort pid;
        uint ecu;
        ubyte offset;
        ubyte length;
        SampleDesc desc;
    }

    static uint response_for(uint request) pure
        => request <= 0x7FF ? request + 8 : (request & 0xFFFF0000) | ((request & 0xFF) << 8) | ((request >> 8) & 0xFF);

    void iface_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void poll_timer_fired(MonoTime)
    {
        issue_requests();
    }

    void window_fired(MonoTime)
    {
        if (!_outstanding)
            return;
        conclude_request();
        release_in_flight(getTime());

        if (_out_responses == 0)
        {
            if (++_misses >= miss_threshold)
                _asleep = true;
            if (_discovering)
                discovery_page_missed();
        }
        else if (_wake_discovery_pending)
        {
            _wake_discovery_pending = false;
            begin_discovery();
        }
        else if (_discovering)
            discovery_window_closed();

        issue_requests();
    }

    void issue_requests()
    {
        if (_outstanding)
            return;

        MonoTime now = getTime();

        if (_asleep)
        {
            if (now - _sent_time < probe_interval)
                return arm_poll(_sent_time + probe_interval);
            static immutable ubyte[2] probe = [0x01, 0x00];
            send_request(0, false, probe[]);
            return;
        }

        if (_discovering)
        {
            ubyte[2] req = [0x01, cast(ubyte)(_mask_page * 0x20)];
            send_request(0, false, req[]);
            return;
        }

        size_t i = 0;
        MonoTime next_due = MonoTime(ulong.max);
        for (; i < elements.length; ++i)
        {
            ref SampleElement e = elements[i];
            if ((e.flags & 3) || e.sampleTimeMs == ushort.max)
                continue;
            MonoTime due = e.lastUpdate + msecs(e.sampleTimeMs);
            if (due <= now)
                break;
            if (due < next_due)
                next_due = due;
        }
        if (i == elements.length)
        {
            if (next_due != MonoTime(ulong.max))
                arm_poll(next_due);
            return;
        }

        ref SampleElement first = elements[i];
        ubyte[8] req = void;
        size_t len = 0;
        req[len++] = first.mode;

        if (first.mode == 0x22)
        {
            req[len++] = first.pid >> 8;
            req[len++] = first.pid & 0xFF;
            mark_in_flight(first.mode, first.pid, first.ecu);
        }
        else
        {
            // J1979 allows up to 6 pids per request
            ushort[6] pids = void;
            size_t num_pids = 0;
            pids[num_pids++] = first.pid;
            foreach (ref e; elements[i + 1 .. $])
            {
                if (num_pids == pids.length)
                    break;
                if ((e.flags & 3) || e.sampleTimeMs == ushort.max || now - e.lastUpdate < msecs(e.sampleTimeMs))
                    continue;
                if (e.mode != first.mode || e.ecu != first.ecu)
                    continue;
                bool have = false;
                foreach (p; pids[0 .. num_pids])
                    have |= p == e.pid;
                if (!have)
                    pids[num_pids++] = e.pid;
            }
            foreach (p; pids[0 .. num_pids])
            {
                req[len++] = cast(ubyte)p;
                mark_in_flight(first.mode, p, first.ecu);
            }
        }

        send_request(first.ecu, first.ecu > 0x7FF, req[0 .. len]);
    }

    void release_in_flight(MonoTime now)
    {
        foreach (ref e; elements)
        {
            if (e.flags & 1)
            {
                e.flags &= ~1;
                e.lastUpdate = now;
            }
        }
    }

    void clear_in_flight()
    {
        foreach (ref e; elements)
            e.flags &= ~1;
    }

    void send_request(uint ecu, bool extended, const(ubyte)[] request)
    {
        _sent_time = getTime();
        _outstanding = true;
        _dispatched = false;
        _dispatch_handle = 0;
        _out_mode = request[0];
        _out_dst = ecu;
        _out_responses = 0;
        if (_out_mode == 0x22)
        {
            _out_pids[0] = (request[1] << 8) | request[2];
            _out_num_pids = 1;
        }
        else
        {
            _out_num_pids = cast(ubyte)(request.length - 1);
            foreach (i; 0 .. _out_num_pids)
                _out_pids[i] = request[1 + i];
        }

        // the dispatch callback may fire inline from submit, or later when a queued
        // transport (ELM327) actually writes the request to the adapter
        int r = submit(ecu, extended, request);
        if (r < 0)
        {
            // never accepted; the request's elements stay eligible for the retry
            _outstanding = false;
            clear_in_flight();
            arm_poll(_sent_time + retry_interval);
            return;
        }
        _dispatch_handle = r;
        if (_outstanding && !_dispatched)
            arm_window(submission_timeout);
    }

    void on_dispatch(int, MessageState state)
    {
        if (!_outstanding)
            return;
        if (state == MessageState.complete || state == MessageState.in_flight)
        {
            // the request hit the wire; response timing starts here
            _dispatched = true;
            arm_window(request_timeout);
            return;
        }
        // dropped before reaching the wire; retry
        _outstanding = false;
        _dispatch_handle = 0;
        clear_in_flight();
        arm_poll(getTime() + retry_interval);
    }

    void conclude_request()
    {
        _outstanding = false;
        disarm_window();
        if (!_dispatched && _dispatch_handle > 0)
            abort_dispatch(_dispatch_handle);
        _dispatch_handle = 0;
    }

    // an ECU only echoes pids it was asked for, so first-pid membership identifies our reply
    bool response_matches(ubyte mode, uint src, const(ubyte)[] payload)
    {
        if (!_outstanding || mode != _out_mode)
            return false;
        if (_out_dst && src != response_for(_out_dst))
            return false;
        if (mode == 0x22)
            return payload.length >= 3 && ((payload[1] << 8) | payload[2]) == _out_pids[0];
        if (payload.length < 2)
            return false;
        foreach (p; _out_pids[0 .. _out_num_pids])
        {
            if (p == payload[1])
                return true;
        }
        return false;
    }

    void mark_in_flight(ubyte mode, ushort pid, uint ecu)
    {
        foreach (ref e; elements)
        {
            if (e.mode == mode && e.pid == pid && e.ecu == ecu)
                e.flags |= 1;
        }
    }

    // mode-01 supported-pid bitmasks (pids 0x00, 0x20, ...) let the poll skip pids the
    // car will never answer. Resets discovery bookkeeping only, never request state
    void begin_discovery()
    {
        _discovering = false;
        _mask_page = 0;
        _mask_have = 0;
        _mask[] = 0;
        _mask_pages_needed = 0;

        ushort max_pid = 0;
        foreach (ref e; elements)
        {
            e.flags &= ~3;
            if (e.mode == 0x01 && e.pid > max_pid)
                max_pid = e.pid;
        }
        if (max_pid == 0)
            return;
        _mask_pages_needed = cast(ubyte)(((max_pid - 1) / 0x20) + 1);
        if (_mask_pages_needed > _mask.length)
            _mask_pages_needed = _mask.length;
        _discovering = true;
    }

    void discovery_page_missed()
    {
        if (_mask_page == 0)
            return; // no answer at all; asleep handling owns this
        // page unsupported: everything from here up is unsupported
        finish_discovery();
    }

    // masks from every responding ECU union; a pid any ECU implements stays polled
    void discovery_page_received(ubyte page, uint mask)
    {
        if (!_discovering || page != _mask_page)
            return;
        _mask[page] |= mask;
        _mask_have |= cast(ubyte)(1 << page);
    }

    void discovery_window_closed()
    {
        if (!(_mask_have & (1 << _mask_page)))
        {
            finish_discovery();
            return;
        }
        // bit0 of each page advertises the next page
        if (_mask_page + 1 < _mask_pages_needed && (_mask[_mask_page] & 1))
        {
            ++_mask_page;
            return;
        }
        finish_discovery();
    }

    void finish_discovery()
    {
        _discovering = false;
        foreach (ref e; elements)
        {
            if (e.mode != 0x01 || e.pid == 0 || (e.pid & 0x1F) == 0)
                continue;
            ubyte page = cast(ubyte)((e.pid - 1) / 0x20);
            bool supported = false;
            if (_mask_have & (1 << page))
                supported = (_mask[page] & (0x8000_0000u >> ((e.pid - 1) & 0x1F))) != 0;
            if (!supported)
            {
                e.flags |= 2;
                log.debug_("pid ", e.pid, " not supported by vehicle");
            }
        }
    }

    void packet_handler(ref const Packet p, BaseInterface, PacketDirection, void*)
    {
        if (p.type != PacketType.obd)
            return;

        const(ubyte)[] payload = cast(const(ubyte)[])p.data;
        if (payload.length < 2)
            return;
        uint src = p.hdr!OBDFrame.src_id;
        MonoTime now = p.creation_time;

        // negative response [7F, echoed service, NRC]: a reply, not silence; it completes
        // the request without sampling, except response-pending which extends the wait
        if (payload[0] == 0x7F)
        {
            if (payload.length < 3 || !_outstanding || payload[1] != _out_mode)
                return;
            if (_out_dst && src != response_for(_out_dst))
                return;
            version (DebugOBDBinding)
                log.debugf("negative response: service {0,02x} nrc {1,02x}", payload[1], payload[2]);
            _misses = 0;
            if (_asleep)
            {
                _asleep = false;
                _wake_discovery_pending = true;
            }
            if (payload[2] == 0x78)
            {
                arm_window(request_timeout);
                return;
            }
            if (_out_dst)
            {
                conclude_request();
                release_in_flight(now);
                issue_requests();
            }
            else
            {
                ++_out_responses;
                arm_window(collection_window);
            }
            return;
        }

        if (!(payload[0] & 0x40))
            return;
        ubyte mode = payload[0] & 0x3F;

        // only a reply carrying a requested pid from the right source correlates; anything
        // else (late replies, other testers' traffic) must not complete the request,
        // reset the miss count, wake an asleep binding, or be sampled
        if (!response_matches(mode, src, payload))
            return;

        _misses = 0;
        if (_asleep)
        {
            // let the probe finish through its collection window; discovery starts when it closes
            _asleep = false;
            _wake_discovery_pending = true;
        }

        // a physical reply completes the request; a functional reply holds the
        // collection window open for sibling ECUs
        if (_outstanding)
        {
            if (_out_dst)
            {
                conclude_request();
                release_in_flight(now);
            }
            else
            {
                ++_out_responses;
                arm_window(collection_window);
            }
        }

        if (mode == 0x22)
        {
            if (payload.length >= 3)
            {
                ushort did = (payload[1] << 8) | payload[2];
                sample_elements(mode, did, src, payload[3 .. $], now);
            }
            issue_requests();
            return;
        }

        // J1979 responses may carry several pids: [mode+40][pid][data...][pid][data...]
        size_t i = 1;
        while (i < payload.length)
        {
            ubyte pid = payload[i];

            if (_discovering && mode == 0x01 && (pid & 0x1F) == 0)
            {
                if (payload.length >= i + 5)
                {
                    uint mask = (payload[i+1] << 24) | (payload[i+2] << 16) | (payload[i+3] << 8) | payload[i+4];
                    discovery_page_received(pid / 0x20, mask);
                }
                i += 5;
                continue;
            }

            size_t span = pid_span(mode, pid, src);
            if (span == 0)
                break; // unknown pid; can't walk any further
            if (i + 1 + span > payload.length)
                span = payload.length - i - 1;
            sample_elements(mode, pid, src, payload[i + 1 .. i + 1 + span], now);
            i += 1 + span;
        }

        issue_requests();
    }

    size_t pid_span(ubyte mode, ushort pid, uint src)
    {
        size_t span = 0;
        foreach (ref e; elements)
        {
            if (e.mode != mode || e.pid != pid)
                continue;
            if (e.ecu && response_for(e.ecu) != src)
                continue;
            if (e.offset + e.length > span)
                span = e.offset + e.length;
        }
        return span;
    }

    void sample_elements(ubyte mode, ushort pid, uint src, const(ubyte)[] data, MonoTime now)
    {
        foreach (ref e; elements)
        {
            if (e.mode != mode || e.pid != pid)
                continue;
            if (e.ecu && response_for(e.ecu) != src)
                continue;
            if (e.offset + e.length > data.length)
                continue;

            const(void)[] wire = data[e.offset .. e.offset + e.length];
            SysTime t = cast(SysTime)now;

            Element* el = e.element;
            const(DataFormat)* fmt = e.desc.fmt;
            if (fmt.is_scalar)
            {
                Scalar s;
                s.raw[] = 0;
                if (!sample_record(wire, e.desc, s.raw[0 .. fmt.stride]))
                    continue;
                if (el.format == e.desc.format)
                    el.write_record(s.raw[0 .. fmt.stride], t);
                else
                    el.value(box_record(s.raw.ptr, *fmt), t);
            }
            else if (fmt.type == ValueType.char_)
            {
                char[64] buf = void;
                el.value(Variant(sample_text(wire, e.desc, buf)), t);
            }
            else
            {
                ubyte[64] rec = void;
                if (fmt.stride <= rec.length && sample_record(wire, e.desc, rec[0 .. fmt.stride]))
                    el.value(box_record(rec.ptr, *fmt), t);
            }

            e.flags &= ~1;
            e.lastUpdate = now;
            if (e.sampleTimeMs == 0)
                e.flags |= 2;

            version (DebugOBDBinding)
                log.debugf("sample - mode: {0,02x} pid: {1,04x} element: {2} = {3}", mode, pid, el.id, el.value);
        }
    }
}


// ====================================================================
// Tests
// ====================================================================

unittest
{
    import urt.mem.allocator;

    // An OBDBinding allocated directly (no Application/collection harness), with the
    // transport and timer edges overridden so the test drives the scheduler.
    static class TestBinding : OBDBinding
    {
    nothrow @nogc:
        uint submits;
        bool fail_submit;
        bool defer_dispatch;
        ubyte[8] last_req;
        size_t last_len;
        uint last_ecu;
        uint windows_armed;
        uint polls_armed;
        uint aborts;

        this()
        {
            super(CID(1));      // dummy id for the mock; never registered in a table
        }

        override int submit(uint ecu, bool extended, const(ubyte)[] request)
        {
            if (fail_submit)
                return -1;
            ++submits;
            last_ecu = ecu;
            last_req[0 .. request.length] = request[];
            last_len = request.length;
            if (defer_dispatch)
                return submits;     // queued; the test reports dispatch later
            on_dispatch(0, MessageState.complete);
            return 0;
        }

        override void abort_dispatch(int) { ++aborts; }
        override void arm_window(Duration) { ++windows_armed; }
        override void disarm_window() {}
        override void arm_poll(MonoTime) { ++polls_armed; }
        override void disarm_poll() {}
    }

    TestBinding b = defaultAllocator().allocT!TestBinding();
    scope (exit) defaultAllocator().freeT(b);

    // one functional mode-01 element; response pids below avoid 0x0C so the
    // sampler (which needs a real Element) is never entered
    auto e = &b.elements.pushBack();
    e.mode = 0x01;
    e.pid = 0x0C;
    e.pid_bytes = 1;
    e.length = 2;
    e.sampleTimeMs = 400;

    // failed transmit: the pid must stay eligible and a retry must be scheduled
    b.fail_submit = true;
    b.issue_requests();
    assert(b.submits == 0);
    assert((b.elements[0].flags & 1) == 0);
    assert(b.polls_armed == 1);
    assert(!b._outstanding);

    // the retry succeeds
    b.fail_submit = false;
    b.issue_requests();
    assert(b.submits == 1 && b.last_ecu == 0);
    assert(b.last_req[0 .. 2] == [0x01, 0x0C] && b.last_len == 2);
    assert((b.elements[0].flags & 1) && b._outstanding);
    assert(b.windows_armed == 1);

    // response payloads are truncated (1 data byte for a 2-byte element) so element
    // decode is skipped and the null Element* is never dereferenced
    Packet p;
    static immutable ubyte[3] rsp = [0x41, 0x0C, 0xAA];        // requested pid
    static immutable ubyte[3] other_pid = [0x41, 0x0D, 0xAA];  // right mode + source, wrong pid
    static immutable ubyte[3] wrong_mode = [0x49, 0x02, 0x01];

    // a reply carrying only un-requested pids must not touch the request
    ref OBDFrame f = p.init!OBDFrame(other_pid[]);
    f.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding && b.submits == 1 && b.windows_armed == 1);

    // functional query: the first matching reply holds the window open rather than completing
    ref OBDFrame g = p.init!OBDFrame(rsp[]);
    g.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding && b.submits == 1);
    assert(b.windows_armed == 2);   // re-armed to the collection window

    // a sibling ECU reply also lands inside the window
    g.src_id = 0x7E9;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding && b.submits == 1);
    assert(b.windows_armed == 3);

    // a wrong-mode response never completes the request
    ref OBDFrame h = p.init!OBDFrame(wrong_mode[]);
    h.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding && b.submits == 1);
    assert(b.windows_armed == 3);

    // only the window closing releases the request and re-times the elements
    uint polls_before = b.polls_armed;
    b.window_fired(MonoTime.init);
    assert(!b._outstanding);
    assert((b.elements[0].flags & 1) == 0);
    assert(b.submits == 1);
    assert(b.polls_armed == polls_before + 1);  // next poll scheduled at the element's due time
    assert(b._misses == 0);                     // replies arrived; not a miss

    // physical requests complete only on the matching ECU's reply to a requested pid
    b.elements[0].ecu = 0x7E0;
    b.elements[0].lastUpdate = MonoTime.init;
    b.issue_requests();
    assert(b.submits == 2 && b.last_ecu == 0x7E0);
    ref OBDFrame q = p.init!OBDFrame(rsp[]);
    q.src_id = 0x7E9;   // wrong ECU: ignored
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding);
    ref OBDFrame r = p.init!OBDFrame(other_pid[]);
    r.src_id = 0x7E8;   // right ECU, but a 41 0D reply must not complete an 01 0C request
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding);
    ref OBDFrame s = p.init!OBDFrame(rsp[]);
    s.src_id = 0x7E8;   // 0x7E0's responder answering the requested pid
    polls_before = b.polls_armed;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(!b._outstanding);
    assert(b.submits == 2 && b.polls_armed == polls_before + 1);

    // an asleep binding ignores traffic that answers nothing it asked for
    b._asleep = true;
    b._misses = OBDBinding.miss_threshold;
    ref OBDFrame t = p.init!OBDFrame(rsp[]);
    t.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._asleep && b._misses == OBDBinding.miss_threshold);

    // only a reply to its own probe wakes it, and waking must not transmit until
    // the probe's collection window expires
    b._sent_time = MonoTime.init;
    b.issue_requests();
    assert(b.submits == 3 && b.last_req[0 .. 2] == [0x01, 0x00]);
    static immutable ubyte[6] mask_rsp = [0x41, 0x00, 0x00, 0x00, 0x00, 0x01];
    ref OBDFrame u = p.init!OBDFrame(mask_rsp[]);
    u.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(!b._asleep && b._misses == 0);
    assert(b._outstanding && b.submits == 3);
    assert(!b._discovering);            // discovery deferred to the window close

    // a sibling ECU's probe reply also lands in the open window
    u.src_id = 0x7E9;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding && b.submits == 3);

    // the window closing starts discovery with a fresh page-0 request
    b.window_fired(MonoTime.init);
    assert(b._discovering && b.submits == 4);
    assert(b.last_ecu == 0 && b.last_req[0 .. 2] == [0x01, 0x00]);

    // page-0 reply + window close finishes discovery; mask 0x00000001 excludes pid 0x0C
    u.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    b.window_fired(MonoTime.init);
    assert(!b._discovering);
    assert(b.elements[0].flags & 2);

    // rediscovery with pid 0x0C supported re-enables it
    b.begin_discovery();
    b.issue_requests();
    assert(b.submits == 5);
    static immutable ubyte[6] mask_sup = [0x41, 0x00, 0x00, 0x10, 0x00, 0x00];
    ref OBDFrame v = p.init!OBDFrame(mask_sup[]);
    v.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    b.window_fired(MonoTime.init);
    assert(!b._discovering && (b.elements[0].flags & 2) == 0);

    // a further rediscovery without it must not inherit the stale supported bit
    b.begin_discovery();
    b.issue_requests();
    assert(b.submits == 6);
    ref OBDFrame w = p.init!OBDFrame(mask_rsp[]);
    w.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    b.window_fired(MonoTime.init);
    assert(!b._discovering);
    assert(b.elements[0].flags & 2);

    // a negative response is a reply, not silence: it completes and keeps the vehicle awake
    b.elements[0].flags = 0;
    b.elements[0].lastUpdate = MonoTime.init;
    b._misses = 2;
    b.issue_requests();
    assert(b.submits == 7 && b.last_ecu == 0x7E0);
    static immutable ubyte[3] nrc = [0x7F, 0x01, 0x12];
    ref OBDFrame x = p.init!OBDFrame(nrc[]);
    x.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(!b._outstanding && b._misses == 0);

    // response-pending (NRC 78) extends the wait instead of completing
    b.elements[0].lastUpdate = MonoTime.init;
    b.issue_requests();
    assert(b.submits == 8);
    uint windows_before = b.windows_armed;
    static immutable ubyte[3] pending = [0x7F, 0x01, 0x78];
    ref OBDFrame y = p.init!OBDFrame(pending[]);
    y.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding && b.windows_armed == windows_before + 1);
    ref OBDFrame z = p.init!OBDFrame(nrc[]);
    z.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(!b._outstanding);

    // a negative echoing a different service does not correlate
    b.elements[0].lastUpdate = MonoTime.init;
    b._misses = 2;
    b.issue_requests();
    assert(b.submits == 9);
    static immutable ubyte[3] nrc_other = [0x7F, 0x22, 0x31];
    ref OBDFrame zz = p.init!OBDFrame(nrc_other[]);
    zz.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(b._outstanding && b._misses == 2);
    b.window_fired(MonoTime.init);
    b._asleep = false;
    b._misses = 0;

    // a queued request does not start response timing until the transport dispatches it
    b.defer_dispatch = true;
    b.elements[0].flags = 0;
    b.elements[0].lastUpdate = MonoTime.init;
    windows_before = b.windows_armed;
    b.issue_requests();
    assert(b.submits == 10);
    assert(b._outstanding && !b._dispatched);
    assert(b.windows_armed == windows_before + 1);   // submission guard only
    b.on_dispatch(10, MessageState.complete);
    assert(b._dispatched);
    assert(b.windows_armed == windows_before + 2);   // response window armed at dispatch

    // a dispatched request completes without aborting anything
    ref OBDFrame nr = p.init!OBDFrame(rsp[]);
    nr.src_id = 0x7E8;
    b.packet_handler(p, null, PacketDirection.incoming, null);
    assert(!b._outstanding && b.aborts == 0);

    // completing (here: timing out) an undispatched request aborts the queued transport entry
    b.elements[0].lastUpdate = MonoTime.init;
    b.issue_requests();
    assert(b.submits == 11 && !b._dispatched);
    b.window_fired(MonoTime.init);
    assert(!b._outstanding && b.aborts == 1);
}
