module protocol.sep2.binding;

import urt.array;
import urt.encoding : hex_encode;
import urt.format.xml;
import urt.lifetime;
import urt.log;
import urt.meta;
import urt.meta.enuminfo : enum_info, enum_key_from_value;
import urt.result;
import urt.si;
import urt.si.quantity;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.expression : NamedArgument;
import manager.sample;
import manager.series;

import protocol.http;
import protocol.http.client;
import protocol.http.message;
import protocol.sep2.der;
import protocol.sep2.schema;
import protocol.tls : Certificate;

//version = DebugSEP2;

nothrow @nogc:


enum Sep2Scheme : ubyte
{
    ieee2030_5,
    csip_aus,
}

// The resource being fetched; its response is handled under the same name.
enum Sep2Phase : ubyte
{
    idle,
    capability,
    time,
    end_device,
    registration,
    assignments,
    programs,
    default_control,
    controls,
    polling,
}

final class Sep2Binding : ProtocolBinding
{
nothrow @nogc:

    enum type_name = "sep2-binding";
    enum path = "/binding/sep2";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Sep2Binding, id, flags);
    }

    ref const(String) remote() const pure
        => _remote;
    StringResult remote(String value)
    {
        if (value.empty)
            return StringResult("remote cannot be empty");
        if (value == _remote)
            return StringResult.success;
        _remote = value.move;
        mark_set!(typeof(this), "remote")();
        restart();
        return StringResult.success;
    }

    inout(Certificate) client_cert() inout pure
        => _client_cert.get;
    void client_cert(Certificate value)
    {
        if (_client_cert.get is value)
            return;
        _client_cert = value;
        mark_set!(typeof(this), "client-cert")();
        restart();
    }

    inout(Certificate) ca() inout pure
        => _ca.get;
    void ca(Certificate value)
    {
        if (_ca.get is value)
            return;
        _ca = value;
        mark_set!(typeof(this), "ca")();
        restart();
    }

    Sep2Scheme scheme() const pure
        => _scheme;
    void scheme(Sep2Scheme value)
    {
        if (_scheme == value)
            return;
        _scheme = value;
        mark_set!(typeof(this), "scheme")();
        restart();
    }

    uint pin() const pure
        => _pin;
    void pin(uint value)
    {
        _pin = value;
        mark_set!(typeof(this), "pin")();
    }

    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("client-cert", client_cert),
                                 Prop!("ca", ca),
                                 Prop!("scheme", scheme),
                                 Prop!("pin", pin));

protected:

    override bool validate() const
    {
        if (_device.empty || _remote.empty || !_client_cert.name.length)
            return false;
        auto url = decompose_http_url(_remote[]);
        return url.scheme.icmp("https") == 0 && !url.host.empty;
    }

    override CompletionStatus startup()
    {
        Certificate cert = _client_cert.get;
        if (!cert || !cert.is_valid)
            return CompletionStatus.continue_;

        if (!_http)
        {
            ubyte[32] digest = cert.fingerprint();
            _lfdi = digest[0 .. 20];
            build_device(sfdi_from_digest(digest));

            const(char)[] client_name = Collection!HTTPClient().generate_name(name[]);
            _http = Collection!HTTPClient().create(client_name, ObjectFlags.dynamic, NamedArgument("remote", _remote[]));
            if (!_http)
            {
                log.error("failed to create HTTP client");
                return CompletionStatus.error;
            }
            _http.client_cert = cert;
            _http.ca = _ca.get;
        }
        if (!_http.running)
            return CompletionStatus.continue_;

        fetch_capability();
        evaluate();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        g_app.cancel(&on_poll);
        g_app.cancel(&on_boundary);
        g_app.cancel(&on_retry);
        if (_http)
        {
            _http.destroy();
            _http = null;
        }
        set_phase(Sep2Phase.idle);
        _programs.clear();
        _pending_lists.clear();
        return super.shutdown();
    }

private:
    struct Program
    {
        DERProgram info;
        bool has_default;
    }

    static immutable string[Limit.max + 1] limit_names = [ "export_limit", "import_limit", "generation_limit", "load_limit" ];

    String _remote;
    ObjectRef!Certificate _client_cert;
    ObjectRef!Certificate _ca;
    HTTPClient _http;

    Element*[Limit.max + 1] _limits;
    Element* _generation_fraction;
    Element* _energize;
    Element* _connect;
    Element* _event;
    Element* _event_start;
    Element* _event_end;
    Element* _phase_e;
    Element* _end_device_e;
    Element* _programs_e;
    Element* _events_e;
    Element* _poll_rate_e;
    Element* _clock_offset_e;

    String _edev_list;
    EndDevice _edev;
    Array!Program _programs;
    Array!String _pending_lists;
    DERSchedule _schedule;

    LFDI _lfdi;
    long _time_offset;
    size_t _walk;
    uint _pin;
    uint _poll_rate;
    ushort _retry_seconds;
    Sep2Scheme _scheme;
    Sep2Phase _phase;

    void build_device(ulong sfdi)
    {
        DeviceBuilder builder = g_app.devices.open(_device[]);
        _bound_device = builder.device;

        Component info = builder.component("info", "DeviceInfo");
        builder.constant(info, "type", "grid-authority");
        builder.constant(info, "name", "IEEE 2030.5 utility server");

        FormatId watts = register_format(DataFormat(ValueType.s32, SeriesKind.held, ScaledUnit(Watt)));
        FormatId flag = register_format(DataFormat(ValueType.bool_, SeriesKind.held));
        FormatId count = register_format(DataFormat(ValueType.u8, SeriesKind.held));
        FormatId time = register_value_format(SysTime());
        DataFormat text_format = DataFormat(ValueType.char_, SeriesKind.held);
        text_format.count = 0;
        FormatId text = register_format(text_format);

        Component sep2 = builder.component("sep2");
        char[40] hex = void;
        hex_encode(_lfdi[], hex);
        builder.constant(sep2, "lfdi", hex[]);
        builder.constant(sep2, "sfdi", sfdi);
        _phase_e = bind_element(builder, sep2, "phase", register_format(DataFormat(ValueType.u8, SeriesKind.held, enum_info!Sep2Phase.make_void())));
        _end_device_e = bind_element(builder, sep2, "end_device", text);
        _programs_e = bind_element(builder, sep2, "programs", count);
        _events_e = bind_element(builder, sep2, "events", count);
        _poll_rate_e = bind_element(builder, sep2, "poll_rate", register_format(DataFormat(ValueType.u32, SeriesKind.held, ScaledUnit(Second))));
        _clock_offset_e = bind_element(builder, sep2, "clock_offset", register_format(DataFormat(ValueType.s32, SeriesKind.held, ScaledUnit(Second))));

        Component authority = builder.component("authority", "GridAuthority");
        builder.constant(authority, "source", _scheme == Sep2Scheme.csip_aus ? "csip-aus" : "ieee2030.5");
        foreach (l, ref e; _limits)
            e = bind_element(builder, authority, limit_names[l], watts);
        _generation_fraction = bind_element(builder, authority, "generation_fraction", register_format(DataFormat(ValueType.f32, SeriesKind.held, Percent)));
        _energize = bind_element(builder, authority, "energize", flag);
        _connect = bind_element(builder, authority, "connect", flag);
        _event = bind_element(builder, authority, "event", text);
        _event_start = bind_element(builder, authority, "event_start", time);
        _event_end = bind_element(builder, authority, "event_end", time);
        builder.commit();
        _bound_device.notify(ComponentEvent.materialised);
    }

    void set_phase(Sep2Phase phase)
    {
        _phase = phase;
        if (_phase_e)
            _phase_e.write_sample(cast(ubyte)phase);
    }

    void fetch(Sep2Phase phase, const(char)[] resource)
    {
        set_phase(phase);
        HTTPParam[1] accept = [ HTTPParam(StringLit!"Accept", StringLit!(sep2_content_type)) ];
        version (DebugSEP2)
            log.debug_("GET ", resource);
        if (!_http.request(HTTPMethod.GET, resource, &on_response, null, null, accept[]))
            fail("request failed");
    }

    // TODO: lists longer than one page lose their tail; follow `all` against `results`
    void fetch_list(Sep2Phase phase, const(char)[] resource)
    {
        fetch(phase, tconcat(resource, "?s=0&l=255"));
    }

    // The committed timeline keeps running while a failed walk is retried; its staged refresh is dropped.
    void fail(const(char)[] why)
    {
        log.warning(why);
        report_poll(false);
        set_phase(Sep2Phase.idle);
        _retry_seconds = _retry_seconds ? cast(ushort)(_retry_seconds >= 150 ? 300 : _retry_seconds * 2) : 5;
        g_app.schedule(getTime() + seconds(_retry_seconds), &on_retry);
    }

    void on_retry(MonoTime)
    {
        if (_phase == Sep2Phase.idle)
            fetch_capability();
    }

    void fetch_capability()
    {
        const(char)[] path = decompose_http_url(_remote[]).path;
        fetch(Sep2Phase.capability, path.length > 1 ? path : "/dcap");
    }

    int on_response(ref const HTTPMessage response)
    {
        const(char)[] what = enum_key_from_value!Sep2Phase(_phase);
        if (_phase == Sep2Phase.capability && (response.status_code == 401 || response.status_code == 404))
        {
            fail(tconcat("HTTP ", response.status_code, ": this certificate's LFDI is not registered with the utility"));
            return 0;
        }
        if (response.status_code < 200 || response.status_code >= 300)
        {
            fail(response.status_code ? tconcat(what, ": HTTP ", response.status_code) : tconcat(what, ": no response"));
            return 0;
        }
        auto r = XmlReader(cast(const(char)[])response.content[]);
        if (r.next() != XmlEvent.start)
        {
            fail(tconcat(what, ": malformed document"));
            return 0;
        }

        final switch (_phase)
        {
            case Sep2Phase.idle:
            case Sep2Phase.polling:
                break;

            case Sep2Phase.capability:
            {
                DeviceCapability dcap;
                decode(r, dcap);
                if (dcap.edev_list.empty)
                {
                    fail("DeviceCapability has no EndDeviceListLink");
                    break;
                }
                _poll_rate = dcap.poll_rate;
                _edev_list = dcap.edev_list.move;
                if (dcap.time.empty)
                    fetch_list(Sep2Phase.end_device, _edev_list[]);
                else
                    fetch(Sep2Phase.time, dcap.time[]);
                break;
            }

            case Sep2Phase.time:
            {
                ServerTime t;
                decode(r, t);
                long offset = t.current - unix_now();
                _clock_offset_e.write_sample(Quantity!(int, ScaledUnit(Second))(cast(int)offset));
                if (offset != _time_offset)
                {
                    // every committed deadline just moved; the armed timer and the published window are stale
                    _time_offset = offset;
                    if (offset < -5 || offset > 5)
                        log.warning("server clock differs by ", offset, "s");
                    evaluate(true);
                }
                fetch_list(Sep2Phase.end_device, _edev_list[]);
                break;
            }

            case Sep2Phase.end_device:
            {
                String previous = _edev.href;
                _edev = EndDevice();
                r.each_child((ref XmlReader c, const(char)[] name) {
                    if (name != "EndDevice" || !_edev.href.empty)
                        return;
                    EndDevice dev;
                    decode(c, dev);
                    if (dev.lfdi == _lfdi)
                        _edev = dev.move;
                });
                if (_edev.href.empty)
                    fail("the server has no EndDevice for this certificate; enrol the LFDI with the utility");
                else if (_edev.fsa_list.empty)
                    fail("EndDevice has no FunctionSetAssignmentsListLink");
                else
                {
                    if (_edev.href != previous)
                        log.info("registered as ", _edev.href);
                    if (_pin && !_edev.registration.empty)
                        fetch(Sep2Phase.registration, _edev.registration[]);
                    else
                        walk_assignments();
                }
                break;
            }

            case Sep2Phase.registration:
            {
                Registration reg;
                decode(r, reg);
                if (reg.pin != _pin)
                    fail(tconcat("registration PIN mismatch (server ", reg.pin, ")"));
                else
                    walk_assignments();
                break;
            }

            case Sep2Phase.assignments:
            {
                note_poll_rate(r);
                r.each_child((ref XmlReader c, const(char)[] name) {
                    if (name != "FunctionSetAssignments")
                        return;
                    FunctionSetAssignments fsa;
                    decode(c, fsa);
                    if (!fsa.derp_list.empty)
                        _pending_lists ~= fsa.derp_list.move;
                });
                next_program_list();
                break;
            }

            case Sep2Phase.programs:
            {
                note_poll_rate(r);
                r.each_child((ref XmlReader c, const(char)[] name) {
                    if (name != "DERProgram")
                        return;
                    Program p;
                    decode(c, p.info);
                    _programs ~= p.move;
                });
                next_program_list();
                break;
            }

            case Sep2Phase.default_control:
            {
                Program* p = &_programs[_walk];
                DERControlBase base;
                decode_default_control(r, base);
                if (base.has(ControlField.setpoint))
                    warn_setpoint("the default control");
                _schedule.offer_default(base, p.info.primacy);
                p.has_default = true;
                next_program();
                break;
            }

            case Sep2Phase.controls:
            {
                note_poll_rate(r);
                ubyte primacy = _programs[_walk].info.primacy;
                r.each_child((ref XmlReader c, const(char)[] name) {
                    if (name != "DERControl")
                        return;
                    DERControl ctl;
                    decode(c, ctl);
                    _schedule.offer(ctl, primacy);
                });
                ++_walk;
                note_activity();
                next_program();
                break;
            }
        }
        return 0;
    }

    void note_poll_rate(ref XmlReader r)
    {
        if (uint rate = poll_rate(r))
            _poll_rate = rate;
    }

    void warn_setpoint(const(char)[] what)
    {
        log.warning(what, " carries a power setpoint (opModFixedW or opModTargetW); not acted on");
    }

    void walk_assignments()
    {
        _programs.clear();
        _pending_lists.clear();
        fetch_list(Sep2Phase.assignments, _edev.fsa_list[]);
    }

    void next_program_list()
    {
        if (_pending_lists.empty)
        {
            _schedule.begin_sync();
            _walk = 0;
            next_program();
            return;
        }
        String list = _pending_lists.front.move;
        _pending_lists.popFront();
        fetch_list(Sep2Phase.programs, list[]);
    }

    void next_program()
    {
        for (; _walk < _programs.length; ++_walk)
        {
            Program* p = &_programs[_walk];
            if (!p.has_default && !p.info.default_control.empty)
            {
                fetch(Sep2Phase.default_control, p.info.default_control[]);
                return;
            }
            if (!p.info.control_list.empty)
            {
                fetch_list(Sep2Phase.controls, p.info.control_list[]);
                return;
            }
        }

        if (_schedule.commit(&respond))
            warn_setpoint("a new event");
        _retry_seconds = 0;
        set_phase(Sep2Phase.polling);
        publish_state();
        evaluate();
        g_app.schedule(getTime() + seconds(_poll_rate ? _poll_rate : 300), &on_poll);
    }

    // Re-walk from the assignments so program membership and primacy stay current.
    void on_poll(MonoTime)
    {
        if (_phase == Sep2Phase.polling)
            walk_assignments();
    }

    void evaluate(bool republish = false)
    {
        g_app.cancel(&on_boundary);
        bool changed;
        long now = unix_now() + _time_offset;
        long boundary = _schedule.evaluate(now, &respond, changed);
        if (changed || republish)
            publish();
        if (boundary > now)
            g_app.schedule(getTime() + seconds(boundary - now), &on_boundary);
    }

    void on_boundary(MonoTime)
    {
        evaluate();
    }

    // Absent direction is published as -1; a limit of 0 W is a real instruction (the backstop).
    void publish()
    {
        const DERControlBase a = _schedule.applied;
        SysTime t = getSysTime();
        foreach (l; Limit.min .. cast(Limit)(Limit.max + 1))
            _limits[l].write_sample(Quantity!(int, ScaledUnit(Watt))(a.has(l) ? a.limit_w[l] : -1), t);
        _generation_fraction.write_sample(Quantity!(float, Percent)(a.has(ControlField.generation_fraction) ? a.generation_pct * 0.01f : -1), t);
        _energize.write_sample(!a.has(ControlField.energize) || a.energize, t);
        _connect.write_sample(!a.has(ControlField.connect) || a.connect, t);

        const(ScheduledEvent)* e = _schedule.active;
        char[32] hex = void;
        if (e)
            hex_encode(e.control.mrid[], hex);
        _event.write_sample(e ? hex[] : "", t);
        _event_start.write_sample(e ? wall_time(e.start) : SysTime(), t);
        _event_end.write_sample(e ? wall_time(e.end) : SysTime(), t);
        log.info("direction changed, event ", e ? hex[] : "none");
    }

    void publish_state()
    {
        SysTime t = getSysTime();
        _end_device_e.write_sample(_edev.href[], t);
        _programs_e.write_sample(cast(ubyte)_programs.length, t);
        _events_e.write_sample(cast(ubyte)_schedule.length, t);
        _poll_rate_e.write_sample(Quantity!(uint, ScaledUnit(Second))(_poll_rate), t);
    }

    void respond(ref const DERControl control, ResponseStatus status)
    {
        if (control.reply_to.empty)
            return;
        DERControlResponse rsp;
        rsp.created = unix_now() + _time_offset;
        rsp.lfdi = _lfdi;
        rsp.subject = control.mrid;
        rsp.status = status;
        char[512] buf = void;
        auto w = XmlWriter(buf);
        write_response(w, rsp);

        HTTPParam[2] headers = [ HTTPParam(StringLit!"Accept", StringLit!(sep2_content_type)),
                                 HTTPParam(StringLit!"Content-Type", StringLit!(sep2_content_type)) ];
        version (DebugSEP2)
            log.debug_("POST ", control.reply_to, " ", w.result);
        if (!_http.request(HTTPMethod.POST, control.reply_to[], &on_response_ack, w.result, null, headers[]))
            log.warning("Response not sent");
    }

    int on_response_ack(ref const HTTPMessage response)
    {
        if (response.status_code < 200 || response.status_code >= 300)
            log.warning("Response rejected: HTTP ", response.status_code);
        return 0;
    }

    static long unix_now()
        => cast(long)(unix_time_ns(getSysTime()) / 1_000_000_000);

    SysTime wall_time(long server_seconds) const
        => from_unix_time_ns(cast(ulong)(server_seconds - _time_offset) * 1_000_000_000);

    // The short-form identifier is the top 36 bits of the digest in decimal, plus a digit that makes the digit sum a multiple of 10.
    static ulong sfdi_from_digest(ref const ubyte[32] d) pure
    {
        ulong v = (cast(ulong)d[0] << 28) | (cast(ulong)d[1] << 20) | (cast(ulong)d[2] << 12) | (cast(ulong)d[3] << 4) | (d[4] >> 4);
        uint sum;
        for (ulong t = v; t; t /= 10)
            sum += cast(uint)(t % 10);
        return v * 10 + (10 - sum % 10) % 10;
    }
}


unittest
{
    // 2030.5 worked example: LFDI 3E4F-45AB-31ED-FE5B-67E3-43E5-E456-2E31-984E-23E5 gives SFDI 167 261 211 391
    ubyte[32] digest = [ 0x3E, 0x4F, 0x45, 0xAB, 0x31, 0xED, 0xFE, 0x5B, 0x67, 0xE3, 0x43, 0xE5, 0xE4, 0x56, 0x2E, 0x31, 0x98, 0x4E, 0x23, 0xE5,
                         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ];
    assert(Sep2Binding.sfdi_from_digest(digest) == 167_261_211_391);
}
