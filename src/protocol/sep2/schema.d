module protocol.sep2.schema;

import urt.conv : parse_uint;
import urt.encoding : hex_decode, hex_encode;
import urt.format.xml;
import urt.string;

nothrow @nogc:


enum sep2_ns = "urn:ieee:std:2030.5:ns";
enum sep2_content_type = "application/sep+xml";

alias MRID = ubyte[16];
alias LFDI = ubyte[20];

struct DeviceCapability
{
    String edev_list;
    String time;
    uint poll_rate;

    private static immutable Field[3] xml = [
        Field("pollRate", poll_rate.offsetof, Kind.attr_uint, poll_rate.sizeof),
        Field("EndDeviceListLink", edev_list.offsetof, Kind.link),
        Field("TimeLink", time.offsetof, Kind.link),
    ];
}

struct ServerTime
{
    long current;

    private static immutable Field[1] xml = [ Field("currentTime", current.offsetof, Kind.int_, current.sizeof) ];
}

struct EndDevice
{
    String href;
    String fsa_list;
    String registration;
    LFDI lfdi;

    private static immutable Field[4] xml = [
        Field("href", href.offsetof, Kind.attr_text),
        Field("lFDI", lfdi.offsetof, Kind.hex_bytes, lfdi.sizeof),
        Field("FunctionSetAssignmentsListLink", fsa_list.offsetof, Kind.link),
        Field("RegistrationLink", registration.offsetof, Kind.link),
    ];
}

struct Registration
{
    uint pin;

    private static immutable Field[1] xml = [ Field("pIN", pin.offsetof, Kind.uint_, pin.sizeof) ];
}

struct FunctionSetAssignments
{
    String derp_list;

    private static immutable Field[1] xml = [ Field("DERProgramListLink", derp_list.offsetof, Kind.link) ];
}

struct DERProgram
{
    String default_control;
    String control_list;
    ubyte primacy;

    private static immutable Field[3] xml = [
        Field("primacy", primacy.offsetof, Kind.uint_, primacy.sizeof),
        Field("DefaultDERControlLink", default_control.offsetof, Kind.link),
        Field("DERControlListLink", control_list.offsetof, Kind.link),
    ];
}

enum Limit : ubyte
{
    export_,
    import_,
    generation,
    load,
}

enum ControlField : ubyte
{
    export_limit = 1 << Limit.export_,
    import_limit = 1 << Limit.import_,
    generation_limit = 1 << Limit.generation,
    load_limit = 1 << Limit.load,
    energize = 0x10,
    connect = 0x20,
    generation_fraction = 0x40,
    setpoint = 0x80,    // carries opModFixedW or opModTargetW, which this client does not act on
}

struct DERControlBase
{
nothrow @nogc:
    int[Limit.max + 1] limit_w;
    ushort generation_pct;  // opModMaxLimW, hundredths of a percent of nameplate
    ubyte fields;
    bool energize;
    bool connect;

    private static immutable Field[9] xml = [
        Field("opModExpLimW", limit_w.offsetof + Limit.export_ * int.sizeof, Kind.watt_limit, 0, ControlField.export_limit),
        Field("opModImpLimW", limit_w.offsetof + Limit.import_ * int.sizeof, Kind.watt_limit, 0, ControlField.import_limit),
        Field("opModGenLimW", limit_w.offsetof + Limit.generation * int.sizeof, Kind.watt_limit, 0, ControlField.generation_limit),
        Field("opModLoadLimW", limit_w.offsetof + Limit.load * int.sizeof, Kind.watt_limit, 0, ControlField.load_limit),
        Field("opModMaxLimW", generation_pct.offsetof, Kind.percent, 0, ControlField.generation_fraction),
        Field("opModEnergize", energize.offsetof, Kind.bool_, 0, ControlField.energize),
        Field("opModConnect", connect.offsetof, Kind.bool_, 0, ControlField.connect),
        Field("opModFixedW", 0, Kind.mark, 0, ControlField.setpoint),
        Field("opModTargetW", 0, Kind.mark, 0, ControlField.setpoint),
    ];

    // DefaultDERControl wraps its base the way an event does.
    private static immutable Field[1] default_xml = [ Field("DERControlBase", 0, Kind.nested, 0, 0, fields.offsetof, xml[]) ];

    bool has(ControlField f) const pure
        => (fields & f) != 0;
    bool has(Limit l) const pure
        => (fields & (1 << l)) != 0;

    DERControlBase merge(ref const DERControlBase over) const pure
    {
        DERControlBase r = this;
        foreach (l; Limit.min .. cast(Limit)(Limit.max + 1))
        {
            if (over.has(l))
                r.limit_w[l] = over.limit_w[l];
        }
        if (over.has(ControlField.generation_fraction))
            r.generation_pct = over.generation_pct;
        if (over.has(ControlField.energize))
            r.energize = over.energize;
        if (over.has(ControlField.connect))
            r.connect = over.connect;
        r.fields |= over.fields & ~ControlField.setpoint;
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
}

struct DERControl
{
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

    private static immutable Field[2] interval_xml = [
        Field("start", start.offsetof, Kind.int_, start.sizeof),
        Field("duration", duration.offsetof, Kind.uint_, duration.sizeof),
    ];
    private static immutable Field[1] status_xml = [ Field("currentStatus", status.offsetof, Kind.uint_, status.sizeof) ];
    private static immutable Field[9] xml = [
        Field("replyTo", reply_to.offsetof, Kind.attr_text),
        Field("responseRequired", response_required.offsetof, Kind.attr_hex, response_required.sizeof),
        Field("mRID", mrid.offsetof, Kind.hex_bytes, mrid.sizeof),
        Field("creationTime", creation_time.offsetof, Kind.int_, creation_time.sizeof),
        Field("randomizeStart", randomize_start.offsetof, Kind.uint_, randomize_start.sizeof),
        Field("randomizeDuration", randomize_duration.offsetof, Kind.int_, randomize_duration.sizeof),
        Field("interval", 0, Kind.nested, 0, 0, ushort.max, interval_xml[]),
        Field("EventStatus", 0, Kind.nested, 0, 0, ushort.max, status_xml[]),
        Field("DERControlBase", base.offsetof, Kind.nested, 0, 0, DERControlBase.fields.offsetof, DERControlBase.xml[]),
    ];
}

enum ResponseStatus : ubyte
{
    received = 1,
    started = 2,
    completed = 3,
    cancelled = 6,
    superseded = 7,
    expired = 252,
}

struct DERControlResponse
{
    long created;
    LFDI lfdi;
    MRID subject;
    ResponseStatus status;
}

// The reader sits on the resource's start element and is left on its end.
void decode(T)(ref XmlReader r, ref T resource)
{
    decode_fields(r, &resource, T.xml[], null);
}

void decode_default_control(ref XmlReader r, ref DERControlBase base)
{
    decode_fields(r, &base, DERControlBase.default_xml[], null);
}

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
{
    const(char)[] v = r.attribute("pollRate");
    size_t taken;
    ulong rate = v.parse_uint(&taken);
    return taken == v.length ? cast(uint)rate : 0;
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

enum Kind : ubyte
{
    attr_text,  // attribute of the resource element -> String
    attr_uint,  // attribute, decimal -> unsigned of `size` bytes
    attr_hex,   // attribute, hex -> unsigned of `size` bytes
    link,       // child element's href -> String
    int_,       // child text -> signed of `size` bytes
    uint_,      // child text -> unsigned of `size` bytes
    percent,    // child text, hundredths of a percent clamped to 10000 -> ushort
    bool_,
    hex_bytes,  // child text -> ubyte[size]
    watt_limit, // child with value and multiplier -> int watts in [0, int.max]
    mark,       // presence only
    nested,     // child element decoded with `sub` at `offset`
}

// `flag` is or-ed into the owner's flags byte; a nested row locates its own with `flags_offset`.
struct Field
{
    string name;
    ushort offset;
    Kind kind;
    ubyte size;
    ubyte flag;
    ushort flags_offset = ushort.max;
    const(Field)[] sub;
}

void decode_fields(ref XmlReader r, void* resource, const(Field)[] fields, ubyte* flags)
{
    foreach (ref f; fields)
    {
        if (f.kind <= Kind.attr_hex)
            store_attribute(r.attribute(f.name), resource + f.offset, f);
    }
    r.each_child((ref XmlReader c, const(char)[] name) {
        foreach (ref f; fields)
        {
            if (f.kind <= Kind.attr_hex || f.name != name)
                continue;
            store_child(c, resource + f.offset, f);
            if (flags)
                *flags |= f.flag;
            return;
        }
    });
}

void store_attribute(const(char)[] text, void* at, ref const Field f)
{
    if (f.kind == Kind.attr_text)
    {
        *cast(String*)at = text.make_string();
        return;
    }
    size_t taken;
    ulong v = text.parse_uint(&taken, f.kind == Kind.attr_hex ? 16 : 10);
    store_integer(at, f.size, taken == text.length ? v : 0);
}

void store_child(ref XmlReader c, void* at, ref const Field f)
{
    final switch (f.kind)
    {
        case Kind.attr_text:
        case Kind.attr_uint:
        case Kind.attr_hex:
        case Kind.mark:
            break;
        case Kind.link:
            *cast(String*)at = c.attribute("href").make_string();
            break;
        case Kind.int_:
            store_integer(at, f.size, cast(ulong)c.element_int());
            break;
        case Kind.uint_:
            store_integer(at, f.size, c.element_uint());
            break;
        case Kind.percent:
            ulong pct = c.element_uint();
            *cast(ushort*)at = cast(ushort)(pct > 10_000 ? 10_000 : pct);
            break;
        case Kind.bool_:
            *cast(bool*)at = c.element_bool();
            break;
        case Kind.hex_bytes:
            ubyte[LFDI.length] tmp = void;
            if (hex_decode(c.element_text().trim, tmp[0 .. f.size]) == f.size)
                (cast(ubyte*)at)[0 .. f.size] = tmp[0 .. f.size];
            break;
        case Kind.watt_limit:
            *cast(int*)at = decode_watt_limit(c);
            break;
        case Kind.nested:
            decode_fields(c, at, f.sub, f.flags_offset == ushort.max ? null : cast(ubyte*)at + f.flags_offset);
            break;
    }
}

void store_integer(void* at, ubyte size, ulong v)
{
    switch (size)
    {
        case 1:  *cast(ubyte*)at = cast(ubyte)v;   break;
        case 2:  *cast(ushort*)at = cast(ushort)v; break;
        case 4:  *cast(uint*)at = cast(uint)v;     break;
        default: *cast(ulong*)at = v;              break;
    }
}

// ActivePower as value * 10^multiplier, saturated. A negative limit means nothing and would read as the
// not-directed sentinel, so it becomes the most restrictive value instead.
int decode_watt_limit(ref XmlReader r)
{
    long value, mult;
    r.each_child((ref XmlReader c, const(char)[] name) {
        if (name == "value")
            value = c.element_int();
        else if (name == "multiplier")
            mult = c.element_int();
    });
    if (value <= 0 || mult < -9)
        return 0;
    if (value > int.max || mult > 9)
        return int.max;
    for (; mult > 0; --mult)
    {
        if (value > int.max / 10)
            return int.max;
        value *= 10;
    }
    for (; mult < 0; ++mult)
        value /= 10;
    return cast(int)value;
}

unittest
{
    enum derc = `<DERControl xmlns="urn:ieee:std:2030.5:ns" href="/derp/1/derc/7" replyTo="/rsps/1/rsp" responseRequired="03">
  <mRID>ABCDEF0123456789ABCDEF0123456789</mRID>
  <creationTime>1700000000</creationTime>
  <EventStatus><currentStatus>4</currentStatus><dateTime>1700000000</dateTime><potentiallySuperseded>false</potentiallySuperseded></EventStatus>
  <interval><duration>3600</duration><start>1700003600</start></interval>
  <randomizeStart>10</randomizeStart>
  <randomizeDuration>-5</randomizeDuration>
  <DERControlBase>
    <opModExpLimW><multiplier>3</multiplier><value>2</value></opModExpLimW>
    <opModImpLimW><multiplier>0</multiplier><value>4500</value></opModImpLimW>
    <opModEnergize>false</opModEnergize>
    <opModMaxLimW>7550</opModMaxLimW>
    <opModFixedW>-2500</opModFixedW>
    <opModVoltVar href="/curve/1"/>
  </DERControlBase>
</DERControl>`;
    auto r = XmlReader(derc);
    assert(r.next() == XmlEvent.start);
    DERControl c;
    decode(r, c);
    assert(r.event == XmlEvent.end && r.depth == 0);
    assert(c.reply_to == "/rsps/1/rsp" && c.response_required == 3);
    assert(c.mrid[0] == 0xAB && c.mrid[15] == 0x89);
    assert(c.creation_time == 1700000000 && c.start == 1700003600 && c.duration == 3600);
    assert(c.randomize_start == 10 && c.randomize_duration == -5 && c.status == EventState.superseded);
    assert(c.base.fields == (ControlField.export_limit | ControlField.import_limit | ControlField.energize | ControlField.generation_fraction | ControlField.setpoint));
    assert(c.base.limit_w[Limit.export_] == 2000 && c.base.limit_w[Limit.import_] == 4500 && !c.base.energize);
    assert(c.base.generation_pct == 7550);

    DERControlBase def;
    def.fields = ControlField.export_limit | ControlField.generation_limit;
    def.limit_w[Limit.export_] = 5000;
    def.limit_w[Limit.generation] = 10000;
    DERControlBase m = def.merge(c.base);
    assert(m.limit_w[Limit.export_] == 2000 && m.limit_w[Limit.import_] == 4500 && m.limit_w[Limit.generation] == 10000);
    assert(!m.energize && m.generation_pct == 7550 && !m.has(ControlField.setpoint) && m.has(ControlField.generation_limit));

    enum dderc = `<DefaultDERControl href="/derp/1/dderc"><mRID>00</mRID><DERControlBase><opModLoadLimW><multiplier>-1</multiplier><value>12345</value></opModLoadLimW><opModConnect>true</opModConnect></DERControlBase></DefaultDERControl>`;
    auto d = XmlReader(dderc);
    assert(d.next() == XmlEvent.start);
    DERControlBase base;
    decode_default_control(d, base);
    assert(base.fields == (ControlField.load_limit | ControlField.connect) && base.limit_w[Limit.load] == 1234 && base.connect);

    static int limit(const(char)[] value, const(char)[] multiplier)
    {
        import urt.mem.temp : tconcat;
        auto x = XmlReader(tconcat("<opModExpLimW><multiplier>", multiplier, "</multiplier><value>", value, "</value></opModExpLimW>"));
        x.next();
        return decode_watt_limit(x);
    }
    assert(limit("1", "19") == int.max && limit("1", "127") == int.max && limit("1", "9999999999") == int.max);
    assert(limit("2147483647", "0") == int.max && limit("2147483648", "0") == int.max && limit("214748365", "1") == int.max);
    assert(limit("214748364", "1") == 2147483640 && limit("2", "9") == 2_000_000_000 && limit("3", "9") == int.max);
    assert(limit("1", "-19") == 0 && limit("999", "-3") == 0 && limit("1500", "-2") == 15);
    assert(limit("-1", "0") == 0 && limit("-5", "3") == 0 && limit("0", "9") == 0);

    enum edevs = `<EndDeviceList xmlns="urn:ieee:std:2030.5:ns" all="2" results="2" href="/edev" pollRate="900">
  <EndDevice href="/edev/1"><lFDI>0102030405060708090A0B0C0D0E0F1011121314</lFDI><sFDI>123456789012</sFDI>
    <FunctionSetAssignmentsListLink href="/edev/1/fsa" all="1"/><RegistrationLink href="/edev/1/rg"/></EndDevice>
  <EndDevice href="/edev/2"><lFDI>FFFF</lFDI></EndDevice>
</EndDeviceList>`;
    auto l = XmlReader(edevs);
    assert(l.next() == XmlEvent.start && poll_rate(l) == 900);
    EndDevice[2] devs;
    size_t n;
    l.each_child((ref XmlReader e, const(char)[] name) {
        if (name == "EndDevice" && n < devs.length)
            decode(e, devs[n++]);
    });
    assert(n == 2 && l.event == XmlEvent.end && l.depth == 0);
    assert(devs[0].href == "/edev/1" && devs[0].lfdi[0] == 1 && devs[0].lfdi[19] == 0x14);
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
    size_t seen;
    rr.each_child((ref XmlReader e, const(char)[] name) {
        if (name == "createdDateTime")
            seen += e.element_int() == rsp.created;
        else if (name == "status")
            seen += e.element_uint() == ResponseStatus.started;
        else if (name == "subject")
            seen += e.element_text() == "ABCDEF0123456789ABCDEF0123456789";
        else if (name == "endDeviceLFDI")
            seen += e.element_text() == "0102030405060708090A0B0C0D0E0F1011121314";
    });
    assert(seen == 4);
}
