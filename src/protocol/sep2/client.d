module protocol.sep2.client;

import urt.array;
import urt.encoding : hex_encode;
import urt.format.xml;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.meta;
import urt.meta.enuminfo : enum_info;
import urt.result;
import urt.string;
import urt.string.format : tconcat;
import urt.si;
import urt.si.quantity;
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


enum Sep2Phase : ubyte
{
    idle,
    capability,
    time,
    end_device,
    register,
    registration,
    assignments,
    programs,
    controls,
    polling,
}

// Presents the utility as a device: a GridAuthority component carrying the limits in force, which the
// energy app treats as direction from the connection point.
class Sep2Binding : ProtocolBinding
{
nothrow @nogc:

    enum type_name = "sep2-binding";
    enum path = "/binding/sep2";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Sep2Binding, id, flags);
    }

    // Properties...
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

    uint pin() const pure
        => _pin;
    void pin(uint value)
    {
        _pin = value;
        mark_set!(typeof(this), "pin")();
    }

    uint device_category() const pure
        => _device_category;
    void device_category(uint value)
    {
        _device_category = value;
        mark_set!(typeof(this), "device-category")();
    }

    Duration poll() const pure
        => _poll_override;
    void poll(Duration value)
    {
        _poll_override = value;
        mark_set!(typeof(this), "poll")();
    }

    Sep2Phase phase() const pure
        => _phase;

    const(char)[] lfdi() const
    {
        char[40] hex = void;
        hex_encode(_lfdi[], hex);
        return tconcat(hex[]);
    }

    ulong sfdi() const pure
        => _sfdi;

    const(char)[] end_device() const pure
        => _edev.href[];

    uint programs() const pure
        => cast(uint)_programs.length;

    uint events() const pure
        => cast(uint)_schedule.length;

    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("client-cert", client_cert),
                                 Prop!("ca", ca),
                                 Prop!("pin", pin),
                                 Prop!("device-category", device_category),
                                 Prop!("poll", poll),
                                 Prop!("phase", phase),
                                 Prop!("lfdi", lfdi),
                                 Prop!("sfdi", sfdi),
                                 Prop!("end-device", end_device),
                                 Prop!("programs", programs),
                                 Prop!("events", events));

    // API...

    // Server clock, from the Time resource.
    long server_time() const
        => cast(long)(unix_time_ns(getSysTime()) / 1_000_000_000) + _time_offset;

    SysTime wall_time(long server_seconds) const
        => from_unix_time_ns(cast(ulong)(server_seconds - _time_offset) * 1_000_000_000);

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

        ubyte[32] digest = cert.fingerprint();
        _lfdi = digest[0 .. 20];
        _sfdi = sfdi_from_digest(digest);
        if (!materialise())
            return CompletionStatus.error;

        if (!_http)
        {
            const(char)[] client_name = Collection!HTTPClient().generate_name(name[]);
            _http = Collection!HTTPClient().create(client_name, ObjectFlags.dynamic, NamedArgument("remote", _remote[]));
            if (!_http)
            {
                log.error("failed to create HTTP client");
                return CompletionStatus.error;
            }
            _http.client_cert = cert;
            _http.ca = _ca.get;
            _http.subscribe(&http_state_change);
        }
        if (!_http.running)
            return CompletionStatus.continue_;

        set_phase(Sep2Phase.capability);
        get("/dcap", &on_capability);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        g_app.cancel(&on_poll);
        g_app.cancel(&on_boundary);
        g_app.cancel(&on_fail);
        if (_http)
        {
            _http.unsubscribe(&http_state_change);
            _http.destroy();
            _http = null;
        }
        set_phase(Sep2Phase.idle);
        _programs.clear();
        return super.shutdown();
    }

    override bool materialise()
    {
        DeviceBuilder builder = g_app.devices.open(_device[]);
        _bound_device = builder.device;

        Component info = builder.component("info", "DeviceInfo");
        builder.constant(info, "type", "grid-authority");
        builder.constant(info, "name", "IEEE 2030.5 utility server");

        // Protocol state for visibility; not part of any template.
        Component sep2 = builder.component("sep2");
        char[40] hex = void;
        hex_encode(_lfdi[], hex);
        builder.constant(sep2, "lfdi", hex[]);
        builder.constant(sep2, "sfdi", _sfdi);
        DataFormat text = DataFormat(ValueType.char_, SeriesKind.held);
        text.count = 0;
        FormatId text_id = register_format(text);
        _phase_e = bind_element(builder, sep2, "phase", register_format(DataFormat(ValueType.u8, SeriesKind.held, enum_info!Sep2Phase.make_void())));
        _end_device_e = bind_element(builder, sep2, "end_device", text_id);
        _programs_e = bind_element(builder, sep2, "programs", register_format(DataFormat(ValueType.u8, SeriesKind.held)));
        _events_e = bind_element(builder, sep2, "events", register_format(DataFormat(ValueType.u8, SeriesKind.held)));
        _poll_rate_e = bind_element(builder, sep2, "poll_rate", register_format(DataFormat(ValueType.u32, SeriesKind.held, ScaledUnit(Second))));
        _clock_offset_e = bind_element(builder, sep2, "clock_offset", register_format(DataFormat(ValueType.s32, SeriesKind.held, ScaledUnit(Second))));

        Component authority = builder.component("authority", "GridAuthority");
        builder.constant(authority, "source", "csip-aus");
        builder.constant(authority, "mandatory", true);
        FormatId watts = register_format(DataFormat(ValueType.s32, SeriesKind.held, ScaledUnit(Watt)));
        FormatId flag = register_format(DataFormat(ValueType.bool_, SeriesKind.held));
        _export_limit = bind_element(builder, authority, "export_limit", watts);
        _import_limit = bind_element(builder, authority, "import_limit", watts);
        _generation_limit = bind_element(builder, authority, "generation_limit", watts);
        _load_limit = bind_element(builder, authority, "load_limit", watts);
        _energize = bind_element(builder, authority, "energize", flag);
        _connect = bind_element(builder, authority, "connect", flag);
        _event = bind_element(builder, authority, "event", text_id);
        _event_start = bind_element(builder, authority, "event_start", register_value_format(SysTime()));
        _event_end = bind_element(builder, authority, "event_end", register_value_format(SysTime()));
        builder.commit();
        _bound_device.notify(ComponentEvent.materialised);
        return true;
    }

private:
    struct Program
    {
        DERProgram info;
        DERControlBase default_control;
        bool has_default;
    }

    String _remote;
    ObjectRef!Certificate _client_cert;
    ObjectRef!Certificate _ca;
    HTTPClient _http;
    Element* _export_limit;
    Element* _import_limit;
    Element* _generation_limit;
    Element* _load_limit;
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

    DeviceCapability _dcap;
    EndDevice _edev;
    Array!Program _programs;
    Array!String _pending_lists;
    DERSchedule _schedule;

    LFDI _lfdi;
    ulong _sfdi;
    long _time_offset;
    Duration _poll_override;
    uint _pin;
    uint _device_category;
    uint _poll_rate;
    size_t _walk;
    Sep2Phase _phase;

    void http_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.online && _phase == Sep2Phase.idle && running)
            restart();
    }

    void get(const(char)[] resource, HTTPMessageHandler handler)
    {
        HTTPParam[1] accept = [ HTTPParam(StringLit!"Accept", StringLit!(sep2_content_type)) ];
        version (DebugSEP2)
            log.debug_("GET ", resource);
        if (!_http.request(HTTPMethod.GET, resource, handler, null, null, accept[]))
            fail("request failed");
    }

    void get_list(const(char)[] resource, HTTPMessageHandler handler)
    {
        get(tconcat(resource, "?s=0&l=255"), handler);
    }

    void post(const(char)[] resource, const(char)[] body, HTTPMessageHandler handler)
    {
        HTTPParam[2] headers = [ HTTPParam(StringLit!"Accept", StringLit!(sep2_content_type)),
                                 HTTPParam(StringLit!"Content-Type", StringLit!(sep2_content_type)) ];
        version (DebugSEP2)
            log.debug_("POST ", resource, " ", body);
        if (!_http.request(HTTPMethod.POST, resource, handler, body, null, headers[]))
            fail("request failed");
    }

    // Failures surface inside HTTP response dispatch; the restart runs from a timer so shutdown never
    // destroys the HTTP client underneath its own callback.
    void fail(const(char)[] why)
    {
        log.warning(why);
        report_poll(false);
        set_phase(Sep2Phase.idle);
        g_app.schedule(getTime(), &on_fail);
    }

    void on_fail(MonoTime)
    {
        restart();
    }

    void set_phase(Sep2Phase phase)
    {
        _phase = phase;
        if (_phase_e)
            _phase_e.write_sample(cast(ubyte)phase);
    }

    void publish_state()
    {
        SysTime t = getSysTime();
        _end_device_e.write_sample(_edev.href[], t);
        _programs_e.write_sample(cast(ubyte)_programs.length, t);
        _events_e.write_sample(cast(ubyte)_schedule.length, t);
        _poll_rate_e.write_sample(Quantity!(uint, ScaledUnit(Second))(_poll_rate), t);
        _clock_offset_e.write_sample(Quantity!(int, ScaledUnit(Second))(cast(int)_time_offset), t);
    }

    // A response is usable when it arrived, succeeded, and parses to a root element.
    bool open(ref const HTTPMessage response, ref XmlReader r, const(char)[] what)
    {
        if (response.status_code == 0)
        {
            fail(tconcat(what, ": no response"));
            return false;
        }
        if (response.status_code < 200 || response.status_code >= 300)
        {
            fail(tconcat(what, ": HTTP ", response.status_code));
            return false;
        }
        r = XmlReader(cast(const(char)[])response.content[]);
        if (r.next() != XmlEvent.start)
        {
            fail(tconcat(what, ": malformed document"));
            return false;
        }
        return true;
    }

    int on_capability(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "DeviceCapability"))
            return 0;
        _dcap = DeviceCapability();
        parse_device_capability(r, _dcap);
        if (_dcap.edev_list.empty)
        {
            fail("DeviceCapability has no EndDeviceListLink");
            return 0;
        }
        _poll_rate = _dcap.poll_rate;
        if (_dcap.time.empty)
        {
            _time_offset = 0;
            find_end_device();
        }
        else
        {
            set_phase(Sep2Phase.time);
            get(_dcap.time[], &on_time);
        }
        return 0;
    }

    int on_time(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "Time"))
            return 0;
        ServerTime t;
        parse_time(r, t);
        _time_offset = t.current - cast(long)(unix_time_ns(getSysTime()) / 1_000_000_000);
        if (_time_offset < -5 || _time_offset > 5)
            log.warning("server clock differs by ", _time_offset, "s");
        find_end_device();
        return 0;
    }

    void find_end_device()
    {
        set_phase(Sep2Phase.end_device);
        get_list(_dcap.edev_list[], &on_end_device_list);
    }

    int on_end_device_list(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "EndDeviceList"))
            return 0;
        bool found;
        r.each_child((ref XmlReader c, const(char)[] name) {
            if (name != "EndDevice" || found)
                return;
            EndDevice dev;
            parse_end_device(c, dev);
            if (dev.lfdi == _lfdi)
            {
                _edev = dev.move;
                found = true;
            }
        });
        if (found)
        {
            log.info("registered as ", _edev.href);
            check_registration();
            return 0;
        }

        set_phase(Sep2Phase.register);
        EndDevice dev;
        dev.lfdi = _lfdi;
        dev.sfdi = _sfdi;
        dev.changed_time = server_time();
        dev.device_category = _device_category;
        dev.enabled = true;
        char[512] buf = void;
        auto w = XmlWriter(buf);
        write_end_device(w, dev);
        post(_dcap.edev_list[], w.result, &on_end_device_created);
        return 0;
    }

    int on_end_device_created(ref const HTTPMessage response)
    {
        if (response.status_code != 201 || response.header("Location").empty)
        {
            fail(tconcat("EndDevice registration refused: HTTP ", response.status_code));
            return 0;
        }
        log.info("EndDevice created at ", response.header("Location"));
        get(response.header("Location")[], &on_end_device);
        return 0;
    }

    int on_end_device(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "EndDevice"))
            return 0;
        _edev = EndDevice();
        parse_end_device(r, _edev);
        if (_edev.href.empty)
            _edev.href = response.header("Location");
        check_registration();
        return 0;
    }

    void check_registration()
    {
        if (_pin == 0 || _edev.registration.empty)
        {
            walk_assignments();
            return;
        }
        set_phase(Sep2Phase.registration);
        get(_edev.registration[], &on_registration);
    }

    int on_registration(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "Registration"))
            return 0;
        Registration reg;
        parse_registration(r, reg);
        if (reg.pin != _pin)
        {
            fail(tconcat("registration PIN mismatch (server ", reg.pin, ")"));
            return 0;
        }
        walk_assignments();
        return 0;
    }

    void walk_assignments()
    {
        if (_edev.fsa_list.empty)
        {
            fail("EndDevice has no FunctionSetAssignmentsListLink");
            return;
        }
        set_phase(Sep2Phase.assignments);
        _programs.clear();
        get_list(_edev.fsa_list[], &on_assignments);
    }

    int on_assignments(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "FunctionSetAssignmentsList"))
            return 0;
        if (uint rate = poll_rate(r))
            _poll_rate = rate;
        Array!String derp_lists;
        r.each_child((ref XmlReader c, const(char)[] name) {
            if (name != "FunctionSetAssignments")
                return;
            FunctionSetAssignments fsa;
            parse_fsa(c, fsa);
            if (!fsa.derp_list.empty)
                derp_lists ~= fsa.derp_list.move;
        });
        _pending_lists = derp_lists.move;
        set_phase(Sep2Phase.programs);
        next_program_list();
        return 0;
    }

    void next_program_list()
    {
        if (_pending_lists.empty)
        {
            _schedule.begin_sync();
            _walk = 0;
            set_phase(Sep2Phase.controls);
            next_program();
            return;
        }
        String list = _pending_lists.front.move;
        _pending_lists.popFront();
        get_list(list[], &on_programs);
    }

    int on_programs(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "DERProgramList"))
            return 0;
        if (uint rate = poll_rate(r))
            _poll_rate = rate;
        r.each_child((ref XmlReader c, const(char)[] name) {
            if (name != "DERProgram")
                return;
            Program p;
            parse_der_program(c, p.info);
            _programs ~= p.move;
        });
        next_program_list();
        return 0;
    }

    // Each program contributes its default and its event list; defaults are fetched first.
    void next_program()
    {
        if (_walk >= _programs.length)
        {
            _schedule.end_sync();
            set_phase(Sep2Phase.polling);
            publish_state();
            evaluate();
            arm_poll();
            return;
        }
        Program* p = &_programs[_walk];
        if (!p.has_default && !p.info.default_control.empty)
        {
            get(p.info.default_control[], &on_default_control);
            return;
        }
        if (p.info.control_list.empty)
        {
            ++_walk;
            next_program();
            return;
        }
        get_list(p.info.control_list[], &on_controls);
    }

    int on_default_control(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "DefaultDERControl"))
            return 0;
        Program* p = &_programs[_walk];
        p.default_control = DERControlBase();
        parse_default_control(r, p.default_control);
        p.has_default = true;
        _schedule.offer_default(p.default_control, p.info.primacy);
        if (p.info.control_list.empty)
        {
            ++_walk;
            next_program();
            return 0;
        }
        get_list(p.info.control_list[], &on_controls);
        return 0;
    }

    int on_controls(ref const HTTPMessage response)
    {
        XmlReader r;
        if (!open(response, r, "DERControlList"))
            return 0;
        if (uint rate = poll_rate(r))
            _poll_rate = rate;
        Program* p = &_programs[_walk];
        r.each_child((ref XmlReader c, const(char)[] name) {
            if (name != "DERControl")
                return;
            DERControl ctl;
            parse_der_control(c, ctl);
            _schedule.offer(ctl, p.info.primacy, &respond);
        });
        ++_walk;
        note_activity();
        next_program();
        return 0;
    }

    void evaluate()
    {
        g_app.cancel(&on_boundary);
        bool changed;
        long now = server_time();
        long boundary = _schedule.evaluate(now, &respond, changed);
        if (changed)
            publish();
        if (boundary > now)
            g_app.schedule(getTime() + seconds(boundary - now), &on_boundary);
    }

    // Absent direction is published as -1 W; a limit of 0 W is a real instruction (the backstop).
    void publish()
    {
        const DERControlBase a = _schedule.applied;
        SysTime t = getSysTime();
        auto limit(ControlField f, int w)
            => Quantity!(int, ScaledUnit(Watt))(a.has(f) ? w : -1);
        _export_limit.write_sample(limit(ControlField.export_limit, a.export_limit_w), t);
        _import_limit.write_sample(limit(ControlField.import_limit, a.import_limit_w), t);
        _generation_limit.write_sample(limit(ControlField.generation_limit, a.generation_limit_w), t);
        _load_limit.write_sample(limit(ControlField.load_limit, a.load_limit_w), t);
        _energize.write_sample(!a.has(ControlField.energize) || a.energize, t);
        _connect.write_sample(!a.has(ControlField.connect) || a.connect, t);
        const(ScheduledEvent)* e = _schedule.active;
        char[32] hex = void;
        if (e)
            hex_encode(e.control.mrid[], hex);
        _event.write_sample(e ? hex[] : "", t);
        _event_start.write_sample(e ? wall_time(e.start) : SysTime(), t);
        _event_end.write_sample(e ? wall_time(e.end) : SysTime(), t);
        log.info("authority: export=", a.has(ControlField.export_limit) ? a.export_limit_w : -1, "W import=", a.has(ControlField.import_limit) ? a.import_limit_w : -1,
                 "W generation=", a.has(ControlField.generation_limit) ? a.generation_limit_w : -1, "W load=", a.has(ControlField.load_limit) ? a.load_limit_w : -1,
                 "W energize=", !a.has(ControlField.energize) || a.energize, " event=", e ? hex[] : "none");
    }

    void on_boundary(MonoTime)
    {
        if (_phase == Sep2Phase.polling)
            evaluate();
    }

    void arm_poll()
    {
        Duration d = _poll_override != Duration.zero ? _poll_override : seconds(_poll_rate ? _poll_rate : 300);
        g_app.schedule(getTime() + d, &on_poll);
    }

    // Re-walk from the assignments so program membership and primacy stay current.
    void on_poll(MonoTime)
    {
        if (_phase == Sep2Phase.polling)
            walk_assignments();
    }

    void respond(ref const DERControl control, ResponseStatus status)
    {
        if (control.reply_to.empty)
            return;
        DERControlResponse rsp;
        rsp.created = server_time();
        rsp.lfdi = _lfdi;
        rsp.subject = control.mrid;
        rsp.status = status;
        char[512] buf = void;
        auto w = XmlWriter(buf);
        write_response(w, rsp);
        post(control.reply_to[], w.result, &on_response_ack);
    }

    int on_response_ack(ref const HTTPMessage response)
    {
        if (response.status_code < 200 || response.status_code >= 300)
            log.warning("Response rejected: HTTP ", response.status_code);
        return 0;
    }

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
