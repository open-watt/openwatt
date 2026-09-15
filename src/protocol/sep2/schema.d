module protocol.sep2.schema;

import urt.encoding : hex_decode, hex_encode;
import urt.format.xml;
import urt.lifetime;
import urt.string;

nothrow @nogc:


enum sep2_ns = "urn:ieee:std:2030.5:ns";
enum csipaus_ns = "https://csipaus.org/ns";
enum sep2_content_type = "application/sep+xml";

alias MRID = ubyte[16];
alias LFDI = ubyte[20];

struct DeviceCapability
{
    String edev_list;
    String time;
    String mup_list;
    uint poll_rate;
}

struct ServerTime
{
    long current;
    int tz_offset;
    int dst_offset;
}

struct EndDevice
{
    String href;
    String fsa_list;
    String registration;
    String der_list;
    String connection_point;
    LFDI lfdi;
    ulong sfdi;
    long changed_time;
    uint device_category;
    bool enabled;
}

struct Registration
{
    uint pin;
    long registered;
}

struct FunctionSetAssignments
{
    String href;
    String derp_list;
    String time;
}

struct DERProgram
{
    String href;
    String default_control;
    String control_list;
    String active_list;
    MRID mrid;
    ubyte primacy;
}

enum ControlField : ubyte
{
    export_limit = 0x01,
    import_limit = 0x02,
    generation_limit = 0x04,
    load_limit = 0x08,
    energize = 0x10,
    connect = 0x20,
}

struct DERControlBase
{
nothrow @nogc:
    int export_limit_w;
    int import_limit_w;
    int generation_limit_w;
    int load_limit_w;
    ubyte fields;
    bool energize;
    bool connect;

    bool has(ControlField f) const pure
        => (fields & f) != 0;

    // Fields carried by `over` replace this base's; the rest fall through.
    DERControlBase merge(ref const DERControlBase over) const pure
    {
        DERControlBase r = this;
        if (over.has(ControlField.export_limit))
            r.export_limit_w = over.export_limit_w;
        if (over.has(ControlField.import_limit))
            r.import_limit_w = over.import_limit_w;
        if (over.has(ControlField.generation_limit))
            r.generation_limit_w = over.generation_limit_w;
        if (over.has(ControlField.load_limit))
            r.load_limit_w = over.load_limit_w;
        if (over.has(ControlField.energize))
            r.energize = over.energize;
        if (over.has(ControlField.connect))
            r.connect = over.connect;
        r.fields |= over.fields;
        return r;
    }
}

enum EventState : ubyte
{
    scheduled,
    active,
    cancelled,
    cancelled_random,
    superseded,
}

enum ResponseRequired : ubyte
{
    received = 0x01,
    specific = 0x02,
    opt_out = 0x04,
}

struct DERControl
{
    String href;
    String reply_to;
    MRID mrid;
    long creation_time;
    long start;
    uint duration;
    uint randomize_start;
    int randomize_duration;
    DERControlBase base;
    EventState status;
    ubyte response_required;
}

enum ResponseStatus : ubyte
{
    received = 1,
    started = 2,
    completed = 3,
    opt_out = 4,
    opt_in = 5,
    cancelled = 6,
    superseded = 7,
    expired = 252,
    invalid_values = 253,
    not_applicable = 254,
}

struct DERControlResponse
{
    long created;
    LFDI lfdi;
    MRID subject;
    ResponseStatus status;
}

// Decoders take the reader on the resource's start element and consume it through its end.

alias ChildHandler = void delegate(ref XmlReader r, const(char)[] name) nothrow @nogc;

// Visit each child element; a child the handler leaves unconsumed is skipped.
void each_child(ref XmlReader r, scope ChildHandler fn)
{
    if (r.event != XmlEvent.start)
        return;
    int inner = r.depth;
    while (true)
    {
        XmlEvent e = r.next();
        if (e == XmlEvent.start)
        {
            fn(r, r.name);
            if (r.depth > inner)
                r.skip();
        }
        else if (e != XmlEvent.text && (e != XmlEvent.end || r.depth < inner))
            return;
    }
}

uint poll_rate(ref XmlReader r)
    => cast(uint)attr_uint(r, "pollRate");

String link(ref XmlReader r)
{
    String href = r.attribute("href").make_string();
    r.skip();
    return href;
}

bool parse_hex(size_t N)(const(char)[] text, ref ubyte[N] out_)
{
    ubyte[N] tmp = void;
    if (hex_decode(text.trim, tmp[]) != N)
        return false;
    out_ = tmp;
    return true;
}

alias parse_mrid = parse_hex!16;
alias parse_lfdi = parse_hex!20;

// ActivePower and friends: value * 10^multiplier
int parse_scaled(ref XmlReader r)
{
    long value;
    int mult;
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "value")
            value = c.element_int();
        else if (name == "multiplier")
            mult = cast(int)c.element_int();
    });
    for (; mult > 0; --mult)
        value *= 10;
    for (; mult < 0; ++mult)
        value /= 10;
    if (value > int.max)
        return int.max;
    if (value < int.min)
        return int.min;
    return cast(int)value;
}

void parse_device_capability(ref XmlReader r, ref DeviceCapability dcap)
{
    dcap.poll_rate = poll_rate(r);
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "EndDeviceListLink")
            dcap.edev_list = link(c);
        else if (name == "TimeLink")
            dcap.time = link(c);
        else if (name == "MirrorUsagePointListLink")
            dcap.mup_list = link(c);
    });
}

void parse_time(ref XmlReader r, ref ServerTime t)
{
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "currentTime")
            t.current = c.element_int();
        else if (name == "tzOffset")
            t.tz_offset = cast(int)c.element_int();
        else if (name == "dstOffset")
            t.dst_offset = cast(int)c.element_int();
    });
}

void parse_end_device(ref XmlReader r, ref EndDevice dev)
{
    dev.href = r.attribute("href").make_string();
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "lFDI")
            parse_lfdi(c.element_text(), dev.lfdi);
        else if (name == "sFDI")
            dev.sfdi = c.element_uint();
        else if (name == "changedTime")
            dev.changed_time = c.element_int();
        else if (name == "deviceCategory")
            dev.device_category = cast(uint)c.element_uint(16);
        else if (name == "enabled")
            dev.enabled = c.element_bool();
        else if (name == "FunctionSetAssignmentsListLink")
            dev.fsa_list = link(c);
        else if (name == "RegistrationLink")
            dev.registration = link(c);
        else if (name == "DERListLink")
            dev.der_list = link(c);
        else if (name == "ConnectionPointLink")
            dev.connection_point = link(c);
    });
}

void parse_registration(ref XmlReader r, ref Registration reg)
{
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "pIN")
            reg.pin = cast(uint)c.element_uint();
        else if (name == "dateTimeRegistered")
            reg.registered = c.element_int();
    });
}

void parse_fsa(ref XmlReader r, ref FunctionSetAssignments fsa)
{
    fsa.href = r.attribute("href").make_string();
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "DERProgramListLink")
            fsa.derp_list = link(c);
        else if (name == "TimeLink")
            fsa.time = link(c);
    });
}

void parse_der_program(ref XmlReader r, ref DERProgram derp)
{
    derp.href = r.attribute("href").make_string();
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "mRID")
            parse_mrid(c.element_text(), derp.mrid);
        else if (name == "primacy")
            derp.primacy = cast(ubyte)c.element_uint();
        else if (name == "DefaultDERControlLink")
            derp.default_control = link(c);
        else if (name == "DERControlListLink")
            derp.control_list = link(c);
        else if (name == "ActiveDERControlListLink")
            derp.active_list = link(c);
    });
}

void parse_control_base(ref XmlReader r, ref DERControlBase base)
{
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "opModExpLimW")
        {
            base.export_limit_w = parse_scaled(c);
            base.fields |= ControlField.export_limit;
        }
        else if (name == "opModImpLimW")
        {
            base.import_limit_w = parse_scaled(c);
            base.fields |= ControlField.import_limit;
        }
        else if (name == "opModGenLimW")
        {
            base.generation_limit_w = parse_scaled(c);
            base.fields |= ControlField.generation_limit;
        }
        else if (name == "opModLoadLimW")
        {
            base.load_limit_w = parse_scaled(c);
            base.fields |= ControlField.load_limit;
        }
        else if (name == "opModEnergize")
        {
            base.energize = c.element_bool();
            base.fields |= ControlField.energize;
        }
        else if (name == "opModConnect")
        {
            base.connect = c.element_bool();
            base.fields |= ControlField.connect;
        }
    });
}

// DefaultDERControl wraps its base in DERControlBase like an event does.
void parse_default_control(ref XmlReader r, ref DERControlBase base)
{
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "DERControlBase")
            parse_control_base(c, base);
    });
}

void parse_der_control(ref XmlReader r, ref DERControl ctl)
{
    ctl.href = r.attribute("href").make_string();
    ctl.reply_to = r.attribute("replyTo").make_string();
    ctl.response_required = cast(ubyte)attr_uint(r, "responseRequired", 16);
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "mRID")
            parse_mrid(c.element_text(), ctl.mrid);
        else if (name == "creationTime")
            ctl.creation_time = c.element_int();
        else if (name == "randomizeStart")
            ctl.randomize_start = cast(uint)c.element_uint();
        else if (name == "randomizeDuration")
            ctl.randomize_duration = cast(int)c.element_int();
        else if (name == "interval")
        {
            c.each_child((ref XmlReader i, const(char)[] n) {
                if (n == "start")
                    ctl.start = i.element_int();
                else if (n == "duration")
                    ctl.duration = cast(uint)i.element_uint();
            });
        }
        else if (name == "EventStatus")
        {
            c.each_child((ref XmlReader s, const(char)[] n) {
                if (n == "currentStatus")
                    ctl.status = cast(EventState)s.element_uint();
            });
        }
        else if (name == "DERControlBase")
            parse_control_base(c, ctl.base);
    });
}

// Encoders emit a complete document.

void write_end_device(ref XmlWriter w, ref const EndDevice dev)
{
    char[40] hex = void;
    w.declaration();
    w.open("EndDevice");
    w.attr("xmlns", sep2_ns);
    w.element("sFDI", dev.sfdi);
    hex_encode(dev.lfdi[], hex);
    w.element("lFDI", hex[]);
    w.element("changedTime", dev.changed_time);
    w.element("enabled", dev.enabled);
    if (dev.device_category)
    {
        w.open("deviceCategory");
        w.text(ulong(dev.device_category), 16);
        w.close();
    }
    w.close();
}

void write_response(ref XmlWriter w, ref const DERControlResponse rsp)
{
    char[40] hex = void;
    w.declaration();
    w.open("DERControlResponse");
    w.attr("xmlns", sep2_ns);
    w.element("createdDateTime", rsp.created);
    hex_encode(rsp.lfdi[], hex);
    w.element("endDeviceLFDI", hex[]);
    w.element("status", ulong(rsp.status));
    hex_encode(rsp.subject[], hex[0 .. 32]);
    w.element("subject", hex[0 .. 32]);
    w.close();
}

private:

ulong attr_uint(ref XmlReader r, const(char)[] name, uint base = 10)
{
    import urt.conv : parse_uint;
    const(char)[] v = r.attribute(name);
    size_t taken;
    ulong x = v.parse_uint(&taken, base);
    return taken == v.length ? x : 0;
}


unittest
{
    enum derc = `<DERControl xmlns="urn:ieee:std:2030.5:ns" href="/derp/1/derc/7" replyTo="/rsps/1/rsp" responseRequired="03">
  <mRID>ABCDEF0123456789ABCDEF0123456789</mRID>
  <creationTime>1700000000</creationTime>
  <EventStatus><currentStatus>0</currentStatus><dateTime>1700000000</dateTime><potentiallySuperseded>false</potentiallySuperseded></EventStatus>
  <interval><duration>3600</duration><start>1700003600</start></interval>
  <randomizeStart>10</randomizeStart>
  <randomizeDuration>-5</randomizeDuration>
  <DERControlBase>
    <opModExpLimW><multiplier>3</multiplier><value>2</value></opModExpLimW>
    <opModImpLimW><multiplier>0</multiplier><value>4500</value></opModImpLimW>
    <opModEnergize>false</opModEnergize>
  </DERControlBase>
</DERControl>`;
    auto r = XmlReader(derc);
    assert(r.next() == XmlEvent.start);
    DERControl c;
    parse_der_control(r, c);
    assert(r.event == XmlEvent.end && r.depth == 0);
    assert(c.href == "/derp/1/derc/7" && c.reply_to == "/rsps/1/rsp" && c.response_required == 3);
    assert(c.mrid[0] == 0xAB && c.mrid[15] == 0x89);
    assert(c.creation_time == 1700000000 && c.start == 1700003600 && c.duration == 3600);
    assert(c.randomize_start == 10 && c.randomize_duration == -5 && c.status == EventState.scheduled);
    assert(c.base.fields == (ControlField.export_limit | ControlField.import_limit | ControlField.energize));
    assert(c.base.export_limit_w == 2000 && c.base.import_limit_w == 4500 && !c.base.energize);

    DERControlBase def;
    def.fields = ControlField.export_limit | ControlField.generation_limit;
    def.export_limit_w = 5000;
    def.generation_limit_w = 10000;
    DERControlBase m = def.merge(c.base);
    assert(m.export_limit_w == 2000 && m.import_limit_w == 4500 && m.generation_limit_w == 10000 && !m.energize);
    assert(m.fields == (def.fields | c.base.fields));

    enum edevs = `<EndDeviceList xmlns="urn:ieee:std:2030.5:ns" all="2" results="2" href="/edev">
  <EndDevice href="/edev/1"><lFDI>0102030405060708090A0B0C0D0E0F1011121314</lFDI><sFDI>123456789012</sFDI>
    <FunctionSetAssignmentsListLink href="/edev/1/fsa" all="1"/><RegistrationLink href="/edev/1/rg"/></EndDevice>
  <EndDevice href="/edev/2"><lFDI>FFFF</lFDI></EndDevice>
</EndDeviceList>`;
    auto l = XmlReader(edevs);
    assert(l.next() == XmlEvent.start);
    EndDevice[2] devs;
    size_t n;
    l.each_child((ref XmlReader e, const(char)[] name) {
        if (name == "EndDevice" && n < devs.length)
            parse_end_device(e, devs[n++]);
    });
    assert(n == 2 && l.event == XmlEvent.end && l.depth == 0);
    assert(devs[0].href == "/edev/1" && devs[0].lfdi[0] == 1 && devs[0].lfdi[19] == 0x14 && devs[0].sfdi == 123456789012);
    assert(devs[0].fsa_list == "/edev/1/fsa" && devs[0].registration == "/edev/1/rg");
    assert(devs[1].href == "/edev/2" && devs[1].lfdi[0] == 0);

    char[512] buf = void;
    auto w = XmlWriter(buf);
    DERControlResponse rsp;
    rsp.created = 1700000001;
    rsp.lfdi = devs[0].lfdi;
    rsp.subject = c.mrid;
    rsp.status = ResponseStatus.started;
    write_response(w, rsp);
    assert(!w.overflow);
    auto rr = XmlReader(w.result);
    assert(rr.next() == XmlEvent.start && rr.name == "DERControlResponse");
    DERControlResponse back;
    rr.each_child((ref XmlReader e, const(char)[] name) {
        if (name == "createdDateTime")
            back.created = e.element_int();
        else if (name == "endDeviceLFDI")
            parse_lfdi(e.element_text(), back.lfdi);
        else if (name == "status")
            back.status = cast(ResponseStatus)e.element_uint();
        else if (name == "subject")
            parse_mrid(e.element_text(), back.subject);
    });
    assert(back.created == rsp.created && back.lfdi == rsp.lfdi && back.subject == rsp.subject && back.status == rsp.status);
}
