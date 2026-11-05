module protocol.goodwe.module_config;

import protocol.goodwe.message : GoodWeCommitFormat;

nothrow @nogc:

struct GoodWeModuleCommand
{
    ushort length;
    ubyte function_code;
    ubyte family = 1;
}

bool goodwe_module_commit(GoodWeCommitFormat format) pure
    => format == GoodWeCommitFormat.module_network || format == GoodWeCommitFormat.module_password;

const(char)[] goodwe_apn_payload(const(char)[][] fields, ubyte[] payload) pure
{
    if (fields.length != 1 || fields[0].length > 48 || !printable(fields[0]))
        return "APN requires at most forty-eight bytes without control characters";
    if (payload.length != 50)
        return "APN requires a fifty-byte block";
    payload[] = 0;
    payload[1] = cast(ubyte)fields[0].length;
    payload[2 .. 2 + fields[0].length] = cast(const(ubyte)[])fields[0];
    return null;
}

private bool ipv4_text(const(char)[] text) pure
{
    uint value, digits, dots;
    foreach (c; text)
        if (c == '.')
        {
            if (!digits || ++dots > 3)
                return false;
            value = digits = 0;
        }
        else
        {
            if (c < '0' || c > '9' || ++digits > 3 || (value = value * 10 + c - '0') > 255)
                return false;
        }
    return dots == 3 && digits != 0;
}

private bool printable(const(char)[] text) pure
{
    foreach (c; text)
        if (cast(ubyte)c < 32 || c == 127)
            return false;
    return true;
}

const(char)[] goodwe_module_config_payload(GoodWeCommitFormat format, ubyte step, const(char)[][] fields,
    ubyte[] payload, out GoodWeModuleCommand command) pure
{
    command = GoodWeModuleCommand.init;
    if (format == GoodWeCommitFormat.module_password)
    {
        if (fields.length != 1 || fields[0].length < 8 || fields[0].length > 16 || step > 1)
            return "module password requires eight to sixteen characters";
        foreach (c; fields[0])
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
                return "module password permits letters, digits and underscore";
        if (step == 1)
            command.function_code = 12;
        else
        {
            enum prefix = "AT+WAKEY=WPA2PSK,AES,";
            size_t length = prefix.length + fields[0].length + 2;
            if (length > payload.length)
                return "module payload exceeds buffer";
            payload[0 .. prefix.length] = cast(const(ubyte)[])prefix;
            payload[prefix.length .. length - 2] = cast(const(ubyte)[])fields[0];
            payload[length - 2] = 13;
            payload[length - 1] = 10;
            command = GoodWeModuleCommand(cast(ushort)length, 1, 2);
        }
        return null;
    }
    if (format != GoodWeCommitFormat.module_network || fields.length != 8 || step > 2)
        return "module network requires eight fields";
    if (fields[0] != "DHCP" && fields[0] != "static")
        return "module address mode must be DHCP or static";
    if (fields[0] == "static")
        foreach (address; fields[1 .. 5])
            if (!ipv4_text(address))
                return "invalid module IPv4 address";
    if (!fields[5].length || fields[5].length > 32 || !fields[6].length || fields[6].length > 32 ||
        fields[7].length < 8 || fields[7].length > 64)
        return "invalid router SSID, encryption or password length";
    foreach (field; fields)
        if (!printable(field))
            return "module network fields contain control characters";
    size_t offset;
    if (step == 0)
    {
        foreach (i, field; fields[0 .. (fields[0] == "DHCP" ? 1 : 5)])
        {
            if (offset + field.length + (i != 0) > payload.length)
                return "module payload exceeds buffer";
            if (i)
                payload[offset++] = ',';
            payload[offset .. offset + field.length] = cast(const(ubyte)[])field;
            offset += field.length;
        }
        command.function_code = 11;
    }
    else if (step == 1)
    {
        foreach (field; fields[5 .. 8])
        {
            if (offset + field.length + 1 > payload.length)
                return "module payload exceeds buffer";
            payload[offset++] = cast(ubyte)field.length;
            payload[offset .. offset + field.length] = cast(const(ubyte)[])field;
            offset += field.length;
        }
        command.function_code = 10;
    }
    else
        command.function_code = 12;
    command.length = cast(ushort)offset;
    return null;
}

unittest
{
    const(char)[][8] fields = ["static", "192.0.2.10", "255.255.255.0", "192.0.2.1", "192.0.2.1",
        "OpenWatt-Test", "WPA2PSK,AES", "FixtureOnly42"];
    ubyte[246] payload = void;
    GoodWeModuleCommand command;
    assert(!goodwe_module_config_payload(GoodWeCommitFormat.module_network, 0, fields, payload, command).length);
    assert(command.function_code == 11 && command.family == 1);
    assert(cast(const(char)[])payload[0 .. command.length] == "static,192.0.2.10,255.255.255.0,192.0.2.1,192.0.2.1");
    assert(!goodwe_module_config_payload(GoodWeCommitFormat.module_network, 1, fields, payload, command).length);
    assert(command.function_code == 10 && payload[0] == 13 && payload[14] == 11 && payload[26] == 13);
    assert(!goodwe_module_config_payload(GoodWeCommitFormat.module_network, 2, fields, payload, command).length);
    assert(command.function_code == 12 && command.length == 0);
    fields[1] = "192.0.2.999";
    assert(goodwe_module_config_payload(GoodWeCommitFormat.module_network, 0, fields, payload, command).length);
    fields[0] = "DHCP";
    assert(!goodwe_module_config_payload(GoodWeCommitFormat.module_network, 0, fields, payload, command).length);
    assert(cast(const(char)[])payload[0 .. command.length] == "DHCP");
    fields[0] = "FixtureOnly42";
    assert(!goodwe_module_config_payload(GoodWeCommitFormat.module_password, 0, fields[0 .. 1], payload, command).length);
    assert(command.family == 2 && command.function_code == 1);
    assert(cast(const(char)[])payload[0 .. command.length] == "AT+WAKEY=WPA2PSK,AES,FixtureOnly42\r\n");
    fields[0] = "invalid-password";
    assert(goodwe_module_config_payload(GoodWeCommitFormat.module_password, 0, fields[0 .. 1], payload, command).length);
    fields[0] = "internet.example";
    assert(!goodwe_apn_payload(fields[0 .. 1], payload[0 .. 50]).length);
    assert(payload[0] == 0 && payload[1] == 16 && cast(const(char)[])payload[2 .. 18] == fields[0]);
    foreach (b; payload[18 .. 50])
        assert(b == 0);
    fields[0] = "";
    assert(!goodwe_apn_payload(fields[0 .. 1], payload[0 .. 50]).length);
    foreach (b; payload[0 .. 50])
        assert(b == 0);
    fields[0] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    assert(goodwe_apn_payload(fields[0 .. 1], payload[0 .. 50]).length);
}
