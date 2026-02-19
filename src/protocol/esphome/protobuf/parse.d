module protocol.esphome.protobuf.parse;

import protocol.esphome.protobuf;
import urt.array;
import urt.string;
import urt.conv;


// this is all designed to run as CTFE
// we should confirm there are no relics from this code in any output binary...


alias ImportHandler = string delegate(string filename);

struct ProtoSpec
{
    uint syntax; // "proto2/proto3"
    ProtoService[] services;
    ProtoMessage[] messages;
    ProtoEnum[] enums;
}

struct ProtoService
{
    string name;
    ProtoRPC[] rpcs;
}

struct ProtoMessage
{
    string name;
    ProtoOption[] opts;
    ProtoField[] fields;
}

struct ProtoEnum
{
    struct Member
    {
        string key;
        ProtoValue value;
        ProtoOption[] opts;
    }

    string name;
    ProtoOption[] opts;
    Member[] members;
}

struct ProtoOption
{
    string id;
    ProtoValue value;
}

struct ProtoRPC
{
    string name;
    string call_msg;
    string ret_msg;
    ProtoOption[] opts;
}

struct ProtoField
{
    string type;
    string name;
    ProtoOption[] opts;
    bool repeated;
    bool optional;
    ubyte reserved;
    ubyte id;
    ubyte wire_type;
    ushort logical_type;
}

struct ProtoValue
{
    enum Type
    {
        Bool,
        Int,
        Float,
        String,
        Identifier,
    }

    Type type;
    union
    {
        long i;
        double f;
        string s;
    }
}


ProtoSpec load_proto(const(char)[] path, const(char)[] filename) nothrow
{
    import urt.file;
    import urt.mem;

    void[] file = load_file(path ~ filename, defaultAllocator);
    assert(file, "Failed to load proto file: " ~ path ~ filename);
    scope(exit) { defaultAllocator.free(file); }
    return parse_proto(cast(string)file, null);
//    return (cast(string)file, (string import_file) {
//        return cast(string)load_file(path ~ import_file, defaultAllocator);
//    });
}

ProtoSpec parse_proto(string data, ImportHandler import_handler) nothrow
{
    ProtoSpec proto;
    try
        parse(proto, data, import_handler);
    catch (Exception e)
    {
        // parse error!
        // TODO: complain
        assert(false, "Failed to parse proto: " ~ e.msg);
    }

    // now in a second pass, we'll hook up the type names
    foreach (ref msg; proto.messages)
    {
    outer: foreach (ref f; msg.fields)
    {
        if (f.reserved > 0)
            continue;

        TypeInfo* info = f.type in type_map;
        if (info)
        {
            f.wire_type = info.wire_type;
            f.logical_type = info.logical_type;
            continue;
        }

        foreach (ref e; proto.enums)
        {
            if (e.name == f.type)
            {
                f.wire_type = WireType.varint;
                f.logical_type = LogicalType.enum_;// | (i << 4);
                continue outer;
            }
        }

        foreach (ref m; proto.messages)
        {
            if (m.name == f.type)
            {
                f.wire_type = WireType.length_delimited;
                f.logical_type = LogicalType.message;
                continue outer;
            }
        }

        assert(false, "Unknown type: " ~ f.type);
    }
    }
    return proto;
}

void parse(ref ProtoSpec proto, string data, ImportHandler import_handler)
{
    while (true)
    {
        data.seek_next_token();
        if (data.empty())
            break;

        if (data.startsWith("syntax"))
        {
            data = data[6..$];
            data.expect('=');
            auto syntax = data.take_string();
            data.expect(';');

            if (syntax == "proto2")
                proto.syntax = 2;
            else if (syntax == "proto3")
                proto.syntax = 3;
            else
                throw new Exception("Unknown syntax");
        }
        else if (data.startsWith("import"))
        {
            data = data[6..$];
            auto filename = data.take_string();
            data.expect(';');

            if (import_handler)
            {
                string file = import_handler(filename);
                parse(proto, file, import_handler);
            }
        }
        else
        {
            try proto.services ~= data.parse_service();
            catch (WrongItem e)
            {
                try proto.messages ~= data.parse_message();
                catch (WrongItem e)
                {
                    proto.enums ~= data.parse_enum();
                }
            }
        }
    }
}

ProtoRPC parse_rpc(ref string data)
{
    data.seek_next_token();
    if (!data.startsWith("rpc"))
        throw new WrongItem("Expected 'rpc'");
    data = data[3..$];
    ProtoRPC r;
    r.name = data.take_identifier();
    data.expect('(');
    r.call_msg = data.take_identifier();
    data.expect(')');
    data.expect("returns");
    data.expect('(');
    r.ret_msg = data.take_identifier();
    data.expect(')');
    data.expect('{');
    while (!data.check('}'))
        r.opts ~= data.parse_option(true);
    return r;
}

ProtoService parse_service(ref string data)
{
    data.seek_next_token();
    if (!data.startsWith("service"))
        throw new WrongItem("Expected 'service'");
    data = data[7..$];
    ProtoService r;
    r.name = data.take_identifier();
    data.expect('{');
    while (!data.check('}'))
        r.rpcs ~= data.parse_rpc();
    return r;
}

ProtoMessage parse_message(ref string data)
{
    data.seek_next_token();
    if (!data.startsWith("message"))
        throw new WrongItem("Expected 'message'");
    data = data[7..$];
    ProtoMessage r;
    r.name = data.take_identifier();
    data.expect('{');
    while (!data.check('}'))
    {
        try r.opts ~= data.parse_option(true);
        catch (WrongItem e)
            r.fields ~= data.parse_field();
    }
    return r;
}

ProtoEnum parse_enum(ref string data)
{
    data.seek_next_token();
    if (!data.startsWith("enum"))
        throw new WrongItem("Expected 'enum'");
    data = data[4..$];
    ProtoEnum r;
    r.name = data.take_identifier();
    data.expect('{');
    while (!data.check('}'))
    {
        try r.opts ~= data.parse_option(true);
        catch (WrongItem e)
        {
            r.members ~= ProtoEnum.Member(); // TODO: handle non-int values
            ref ProtoEnum.Member m = r.members[$-1];
            m.key = data.take_identifier();
            data.expect('=');
            m.value = data.parse_value(); // TODO: this can be a number, string, or enum value
            if (data.check('['))
            {
                bool first = true;
                while (!data.check(']'))
                {
                    if (first)
                        first = false;
                    else
                        data.expect(',');
                    m.opts ~= data.parse_option(false);
                }
            }
            data.expect(';');
        }
    }
    return r;
}

ProtoOption parse_option(ref string data, bool statement)
{
    if (statement)
    {
        data.seek_next_token();
        if (!data.startsWith("option"))
            throw new WrongItem("Expected 'option'");
        data = data[6..$];
    }
    ProtoOption r;
    if (data.check('('))
    {
        r.id = data.take_identifier();
        data.expect(')');
    }
    else
        r.id = data.take_identifier();
    data.expect('=');
    r.value = data.parse_value();
    if (statement)
        data.expect(';');
    return r;
}

ProtoField parse_field(ref string data)
{
    ProtoField r;
    data.seek_next_token();
    if (data.startsWith("repeated"))
    {
        r.repeated = true;
        data = data[8..$];
        data.expect_whitespace();
    }
    data.seek_next_token();
    if (data.startsWith("optional"))
    {
        r.optional = true;
        data = data[8..$];
        data.expect_whitespace();
    }
    data.seek_next_token();
    if (data.startsWith("reserved"))
    {
        data = data[8..$];
        data.expect_whitespace();
        r.reserved = cast(ubyte)data.take_int();
    }
    else
    {
        r.type = data.take_identifier();
        r.name = data.take_identifier();
        data.expect('=');
        r.id = cast(ubyte)data.take_int();
        if (data.check('['))
        {
            bool first = true;
            while (!data.check(']'))
            {
                if (first)
                    first = false;
                else
                    data.expect(',');
                r.opts ~= data.parse_option(false);
            }
        }
    }
    data.expect(';');
    return r;
}

ProtoValue parse_value(ref string data)
{
    data.seek_next_token();
    if (data.empty())
        throw new Exception("Unexpected end of input");
    if (data[0] == '+' || data[0] == '-' || data[0].is_numeric)
    {
        // number
        size_t i = 0;
        if (data[0] == '+' || data[0] == '-')
            ++i;
        bool is_float = false;
        while (i < data.length)
        {
            if (data[i] == '.' && !is_float)
                is_float = true;
            else if (!data[i].is_numeric)
                break;
            ++i;
        }
        auto num_str = data[0..i];
        data = data[i..$];
        if (is_float)
            return ProtoValue(type: ProtoValue.Type.Float, f: num_str.parse_float());
        else
            return ProtoValue(type: ProtoValue.Type.Int, i: num_str.parse_int());
    }
    else if (data[0] == '"')
    {
        auto str = data.take_string();
        return ProtoValue(type: ProtoValue.Type.String, s: str);
    }
    else if (data.startsWith("true"))
    {
        data = data[4..$];
        return ProtoValue(type: ProtoValue.Type.Bool, i: 1);
    }
    else if (data.startsWith("false"))
    {
        data = data[5..$];
        return ProtoValue(type: ProtoValue.Type.Bool, i: 0);
    }
    else
    {
        auto id = data.take_identifier();
        return ProtoValue(type: ProtoValue.Type.Identifier, s: id);
    }
}


void seek_next_token(ref string data)
{
    while (!data.empty)
    {
        data = data.trimFront;
        if (data.length >= 2 && data[0..2] == "//")
        {
            auto idx = data.findFirst('\n');
            data = data[idx..$];
        }
        else if (data.length >= 2 && data[0..2] == "/*")
        {
            auto idx = data.findFirst("*/");
            if (idx < data.length)
                idx += 2;
            data = data[idx..$];
        }
        else
            break;
    }
}

void expect_whitespace(ref string data)
{
    if (data.empty || !data[0].is_whitespace)
        throw new Exception("Expected whitespace");
    data = data[1..$];
}

void expect(ref string data, char token)
{
    data.seek_next_token();
    if (data.empty || data[0] != token)
        throw new Exception("Expected token: " ~ token);
    data = data[1..$];
}

void expect(ref string data, string token)
{
    data.seek_next_token();
    if (!data.startsWith(token))
        throw new Exception("Expected token");
    data = data[token.length..$];
}

bool check(ref string data, char token)
{
    data.seek_next_token();
    if (data.empty || data[0] != token)
        return false;
    data = data[1..$];
    return true;
}

bool check(ref string data, string token)
{
    data.seek_next_token();
    if (!data.startsWith(token))
        return false;
    data = data[token.length..$];
    return true;
}

long take_int(ref string data)
{
    data.seek_next_token();
    size_t taken;
    long i = data.parse_int(&taken);
    if (taken == 0)
        throw new Exception("Expected integer");
    data = data[taken..$];
    return i;
}

string take_string(ref string data)
{
    data.seek_next_token();
    if (data.empty || (data[0] != '"'))
        throw new Exception("Expected string");
    size_t i = 1;
    while (i < data.length)
    {
        if (data[i] == '\\')
            i += 2;
        else if (data[i] == '"')
            break;
        else
            ++i;
    }
    if (i >= data.length)
        throw new Exception("Unterminated string");
    string result = data[1..i];
    data = data[i + 1..$];
    return result;
}

string take_identifier(ref string data)
{
    data.seek_next_token();
    if (data.empty || !(data[0].is_alpha || data[0] == '_'))
        throw new Exception("Invalid identifier");
    size_t i = 1;
    for (; i < data.length; ++i)
    {
        if (!data[i].is_alpha_numeric && data[i] != '_')
            break;
    }
    return data.takeFront(i);
}


// synthesise D enums and structs...

string generate_enum(ref const ProtoEnum e)
{
    string result = "enum " ~ e.name ~ " {\n";
    foreach (ref member; e.members)
    {
        result ~= "  " ~ member.key ~ " = ";
        if (member.value.type == ProtoValue.Type.Int)
            result ~= to_string(member.value.i);
        else if (member.value.type == ProtoValue.Type.String)
            result ~= "\"" ~ member.value.s ~ "\"";
        else if (member.value.type == ProtoValue.Type.Bool)
            result ~= member.value.i != 0 ? "true" : "false";
        else if (member.value.type == ProtoValue.Type.Identifier)
            assert(false, "TODO: handle this case");
        else
            assert(false, "Invalid enum value type");
        result ~= ",\n";
    }
    result ~= "}\n\n";
    return result;
}

string generate_message(ref const ProtoMessage msg, uint syntax)
{
    string result = "struct " ~ msg.name ~ " {\n  enum syntax = " ~ syntax.to_string() ~ ";\n";
    foreach (ref opt; msg.opts)
        if (opt.id == "id")
            result ~= "  enum id = " ~ opt.value.i.to_string() ~ ";\n";
    result ~= "  this(this) @disable;\n";
    foreach (ref field; msg.fields)
        if (!field.reserved)
            result ~= "  @FieldInfo(" ~ field.id.to_string() ~ ", " ~ field.wire_type.to_string() ~ ", " ~ field.logical_type.to_string() ~ ") " ~
            make_type_for(field) ~ " " ~ field.name ~ ";\n";
    result ~= "}\n\n";
    return result;
}

string to_string(long value)
{
    if (value == 0)
        return "0";
    char[20] buf; // enough for 64-bit integers
    size_t i = buf.length;
    ulong u = value < 0 ? -value : value;
    while (u != 0)
    {
        buf[--i] = '0' + (u % 10);
        u /= 10;
    }
    if (i < 0)
        buf[--i] = '-';
    return buf[i..$].idup;
}

class WrongItem : Exception
{
    this(string msg)
    {
        super(msg);
    }
}

enum LogicalType : ubyte
{
    none = 0,
    bool_,
    int32,
    int64,
    uint32,
    uint64,
    float32,
    float64,
    string,
    bytes,
    enum_,
    message
}

struct TypeInfo
{
    WireType wire_type;
    LogicalType logical_type;
}

enum TypeInfo[string] type_map = [
    "bool":     TypeInfo(WireType.varint, LogicalType.bool_),
    "uint32":   TypeInfo(WireType.varint, LogicalType.uint32),
    "uint64":   TypeInfo(WireType.varint, LogicalType.uint64),
    "sint32":   TypeInfo(WireType.zigzag, LogicalType.int32),
    "sint64":   TypeInfo(WireType.zigzag, LogicalType.int64),
    "int32":    TypeInfo(WireType.varint, LogicalType.int32),
    "int64":    TypeInfo(WireType.varint, LogicalType.int64),
    "fixed32":  TypeInfo(WireType.fixed32, LogicalType.uint32),
    "fixed64":  TypeInfo(WireType.fixed64, LogicalType.uint64),
    "sfixed32": TypeInfo(WireType.fixed32, LogicalType.int32),
    "sfixed64": TypeInfo(WireType.fixed64, LogicalType.int64),
    "float":    TypeInfo(WireType.fixed32, LogicalType.float32),
    "double":   TypeInfo(WireType.fixed64, LogicalType.float64),
    "string":   TypeInfo(WireType.length_delimited, LogicalType.string),
    "bytes":    TypeInfo(WireType.length_delimited, LogicalType.bytes),
];

enum string[] type_names = [
    "void",
    "bool",
    "int",
    "long",
    "uint",
    "ulong",
    "float",
    "double",
    "String",
    "Array!ubyte"
];

string make_type_for(ref const ProtoField field)
{
    ubyte logical_type = field.logical_type & 0xF;
    if (logical_type == LogicalType.enum_)
        return field.type;
    else if (logical_type == LogicalType.message)
        return field.type;
    string type_name = type_names[logical_type];
    if (field.repeated)
        return logical_type == LogicalType.bytes ? "Array!(Array!ubyte)" : "Array!" ~ type_name;
    return type_name;
}
