module protocol.dhcp.option;

import urt.array;
import urt.conv : parse_uint;
import urt.inet;
import urt.lifetime;
import urt.string;
import urt.string.format : tconcat;

import manager;
import manager.base;
import manager.collection;

import protocol.dhcp.message;

nothrow @nogc:


enum DHCPOptionType : ubyte
{
    auto_,      // infer from well-known code; falls back to bytes
    bytes,      // raw bytes, value is whitespace-separated hex (e.g. "01 02 ab cd")
    ip,         // single IPAddr (e.g. "192.168.1.1")
    ip_list,    // comma-separated IPAddrs (e.g. "8.8.8.8,8.8.4.4")
    u8,
    u16,
    u32,
    string_,    // raw text
    bool_,      // "true" / "false"
}


class DHCPOption : BaseObject
{
    alias Properties = AliasSeq!(Prop!("code", code),
                                 Prop!("type", type),
                                 Prop!("value", value));
nothrow @nogc:

    enum type_name = "dhcp-option";
    enum path = "/protocol/dhcp/option";
    enum collection_id = CollectionType.dhcp_option;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!DHCPOption, id, flags);
    }

    // Properties
    ubyte code() const pure
        => _code;
    const(char)[] code(ubyte value)
    {
        if (value == 0 || value == 255)
            return "code 0 (PAD) and 255 (END) are reserved";
        _code = value;
        mark_set!(typeof(this), "code")();
        return null;
    }

    DHCPOptionType type() const pure
        => _type;
    void type(DHCPOptionType value)
    {
        _type = value;
        mark_set!(typeof(this), "type")();
    }

    ref const(String) value() const pure
        => _value;
    void value(String v)
    {
        _value = v.move;
        mark_set!(typeof(this), "value")();
    }

    // Resolve `type` (auto -> well-known infer -> bytes fallback).
    DHCPOptionType resolved_type() const pure
        => _type == DHCPOptionType.auto_ ? infer_type(_code) : _type;

    // Encode value into builder. Returns false on parse error.
    bool to_wire(ref DhcpBuild b) const
    {
        DHCPOptionType t = resolved_type;
        const(char)[] v = _value[];

        final switch (t)
        {
            case DHCPOptionType.auto_:
            case DHCPOptionType.bytes:
                ubyte[256] buf = void;
                size_t n;
                if (!parse_hex_bytes(v, buf[], n))
                    return false;
                b.add_raw_option(_code, buf[0 .. n]);
                return true;
            case DHCPOptionType.ip:
                IPAddr a;
                if (a.fromString(v) <= 0)
                    return false;
                b.add_addr_option(cast(DhcpOption)_code, a);
                return true;
            case DHCPOptionType.ip_list:
                ubyte[252] buf = void;        // 63 IPv4 addrs max in one option
                size_t n;
                size_t off = 0;
                while (off < v.length && n < buf.length)
                {
                    while (off < v.length && (v[off] == ',' || v[off] == ' '))
                        ++off;
                    if (off >= v.length)
                        break;
                    IPAddr a;
                    ptrdiff_t taken = a.fromString(v[off .. $]);
                    if (taken <= 0)
                        return false;
                    buf[n .. n + 4] = a.b[];
                    n += 4;
                    off += taken;
                }
                if (n == 0)
                    return false;
                b.add_raw_option(_code, buf[0 .. n]);
                return true;
            case DHCPOptionType.u8:
                ulong u; size_t taken;
                u = parse_uint(v, &taken);
                if (taken == 0 || u > ubyte.max)
                    return false;
                ubyte[1] one = [cast(ubyte)u];
                b.add_raw_option(_code, one[]);
                return true;
            case DHCPOptionType.u16:
                ulong u; size_t taken;
                u = parse_uint(v, &taken);
                if (taken == 0 || u > ushort.max)
                    return false;
                ubyte[2] two = [cast(ubyte)(u >> 8), cast(ubyte)u];
                b.add_raw_option(_code, two[]);
                return true;
            case DHCPOptionType.u32:
                ulong u; size_t taken;
                u = parse_uint(v, &taken);
                if (taken == 0 || u > uint.max)
                    return false;
                b.add_uint_option(cast(DhcpOption)_code, cast(uint)u);
                return true;
            case DHCPOptionType.string_:
                b.add_raw_option(_code, cast(const(ubyte)[])v);
                return true;
            case DHCPOptionType.bool_:
                ubyte byte_;
                if (v == "true" || v == "1" || v == "yes" || v == "on")
                    byte_ = 1;
                else if (v == "false" || v == "0" || v == "no" || v == "off")
                    byte_ = 0;
                else
                    return false;
                ubyte[1] one = [byte_];
                b.add_raw_option(_code, one[]);
                return true;
        }
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _code != 0;

private:
    ubyte _code;
    DHCPOptionType _type;
    String _value;
}


// Map well-known codes to their RFC 2132 types. Anything not listed defaults to bytes.
DHCPOptionType infer_type(ubyte code) pure
{
    switch (code)
    {
        case 1:   return DHCPOptionType.ip;         // subnet mask
        case 2:   return DHCPOptionType.u32;        // time offset
        case 3:   return DHCPOptionType.ip_list;    // router
        case 4:   return DHCPOptionType.ip_list;    // time servers
        case 6:   return DHCPOptionType.ip_list;    // DNS
        case 7:   return DHCPOptionType.ip_list;    // log servers
        case 12:  return DHCPOptionType.string_;    // hostname
        case 15:  return DHCPOptionType.string_;    // domain name
        case 19:  return DHCPOptionType.bool_;      // ip forwarding
        case 23:  return DHCPOptionType.u8;         // default ip ttl
        case 26:  return DHCPOptionType.u16;        // interface MTU
        case 28:  return DHCPOptionType.ip;         // broadcast address
        case 31:  return DHCPOptionType.bool_;      // perform router discovery
        case 42:  return DHCPOptionType.ip_list;    // NTP servers
        case 44:  return DHCPOptionType.ip_list;    // NetBIOS name servers
        case 50:  return DHCPOptionType.ip;         // requested address
        case 51:  return DHCPOptionType.u32;        // lease time
        case 54:  return DHCPOptionType.ip;         // server identifier
        case 58:  return DHCPOptionType.u32;        // renewal (T1)
        case 59:  return DHCPOptionType.u32;        // rebinding (T2)
        case 119: return DHCPOptionType.string_;    // domain search list
        default:  return DHCPOptionType.bytes;
    }
}


private:

bool parse_hex_bytes(const(char)[] s, ubyte[] out_, ref size_t out_len) pure
{
    out_len = 0;
    size_t i = 0;
    while (i < s.length)
    {
        while (i < s.length && (s[i] == ' ' || s[i] == ',' || s[i] == ':'))
            ++i;
        if (i >= s.length)
            break;
        if (i + 1 >= s.length)
            return false;
        int hi = hex_digit(s[i]);
        int lo = hex_digit(s[i + 1]);
        if (hi < 0 || lo < 0)
            return false;
        if (out_len >= out_.length)
            return false;
        out_[out_len++] = cast(ubyte)((hi << 4) | lo);
        i += 2;
    }
    return true;
}

int hex_digit(char c) pure
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
