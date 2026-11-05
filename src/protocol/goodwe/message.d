module protocol.goodwe.message;

nothrow @nogc:

enum GoodWeModuleFunction : ubyte
{
    version_info = 0x01,
    router_credentials = 0x02,
    network = 0x03,
    server_status = 0x04,
    packet_counters = 0x05,
    module_info = 0x06,
    set_credentials = 0x0A,
    set_network = 0x0B,
    reload = 0x0C,
    router_credentials_extended = 0x0D,
    scan_hotspots = 0x0E,
}

// The AA55 prefix on a dongle Modbus reply is outside the RTU CRC.
struct GoodWeModbusMessage
{
nothrow @nogc:
    const(ubyte)[] payload;
    ubyte unit = 0xF7;
    ubyte function_code;

    static bool decode(const(ubyte)[] data, out GoodWeModbusMessage message, bool prefixed = false) pure
    {
        if (prefixed)
        {
            if (data.length < 2 || data[0] != 0xAA || data[1] != 0x55)
                return false;
            data = data[2 .. $];
        }
        if (data.length < 5 || GoodWeModuleMessage.checksum(data) != 0)
            return false;
        message = GoodWeModbusMessage(data[2 .. $ - 2], data[0], data[1]);
        return true;
    }

    size_t encode(ubyte[] buffer, bool prefixed = false) const pure
    {
        size_t offset = prefixed ? 2 : 0;
        if (payload.length > 252 || buffer.length < payload.length + offset + 4)
            return 0;
        if (prefixed)
        {
            buffer[0] = 0xAA;
            buffer[1] = 0x55;
        }
        buffer[offset] = unit;
        buffer[offset + 1] = function_code;
        buffer[offset + 2 .. offset + 2 + payload.length] = payload;
        ushort crc = GoodWeModuleMessage.checksum(buffer[offset .. offset + 2 + payload.length]);
        buffer[offset + 2 + payload.length] = cast(ubyte)crc;
        buffer[offset + 3 + payload.length] = cast(ubyte)(crc >> 8);
        return offset + 4 + payload.length;
    }

    bool read_data(ushort count, out const(ubyte)[] values) const pure
    {
        if ((function_code != 3 && function_code != 4) || count == 0 || count > 125 || payload.length != 1 + count * 2 || payload[0] != count * 2)
            return false;
        values = payload[1 .. $];
        return true;
    }
}


struct GoodWeModuleMessage
{
nothrow @nogc:
    const(ubyte)[] payload;
    ubyte function_code;
    ubyte family = 1;

    static ushort checksum(const(ubyte)[] data) pure
    {
        ushort crc = 0xFFFF;
        foreach (b; data)
        {
            crc ^= b;
            foreach (_; 0 .. 8)
                crc = cast(ushort)((crc >> 1) ^ ((crc & 1) ? 0xA001 : 0));
        }
        return crc;
    }

    static bool decode(const(ubyte)[] data, out GoodWeModuleMessage message) pure
    {
        if (data.length < 8 || data[0] != 0x5A || data[1] != 0x5A || (data[2] != 1 && data[2] != 2) ||
            data.length != 8 + ((uint(data[4]) << 8) | data[5]))
            return false;
        ushort crc = checksum(data[0 .. $ - 2]);
        if (data[$ - 2] != (crc & 0xFF) || data[$ - 1] != crc >> 8)
            return false;
        message = GoodWeModuleMessage(data[6 .. $ - 2], data[3], data[2]);
        return true;
    }

    size_t encode(ubyte[] buffer) const pure
    {
        if ((family != 1 && family != 2) || payload.length > ushort.max || buffer.length < payload.length + 8)
            return 0;
        buffer[0] = 0x5A;
        buffer[1] = 0x5A;
        buffer[2] = family;
        buffer[3] = function_code;
        buffer[4] = cast(ubyte)(payload.length >> 8);
        buffer[5] = cast(ubyte)payload.length;
        buffer[6 .. 6 + payload.length] = payload;
        ushort crc = checksum(buffer[0 .. 6 + payload.length]);
        buffer[6 + payload.length] = cast(ubyte)crc;
        buffer[7 + payload.length] = cast(ubyte)(crc >> 8);
        return payload.length + 8;
    }
}

struct AA55Message
{
nothrow @nogc:
    const(ubyte)[] payload;
    ubyte source;
    ubyte destination;
    ubyte control;
    ubyte function_code;

    static bool decode(const(ubyte)[] data, out AA55Message message) pure
    {
        if (data.length < 9 || data[0] != 0xAA || data[1] != 0x55 || data.length != 9 + data[6])
            return false;
        ushort sum;
        foreach (b; data[0 .. $ - 2])
            sum += b;
        if (data[$ - 2] != sum >> 8 || data[$ - 1] != (sum & 0xFF))
            return false;
        message = AA55Message(data[7 .. $ - 2], data[2], data[3], data[4], data[5]);
        return true;
    }

    size_t encode(ubyte[] buffer) const pure
    {
        if (payload.length > 255 || buffer.length < payload.length + 9)
            return 0;
        buffer[0] = 0xAA;
        buffer[1] = 0x55;
        buffer[2] = source;
        buffer[3] = destination;
        buffer[4] = control;
        buffer[5] = function_code;
        buffer[6] = cast(ubyte)payload.length;
        buffer[7 .. 7 + payload.length] = payload;
        ushort sum;
        foreach (b; buffer[0 .. 7 + payload.length])
            sum += b;
        buffer[7 + payload.length] = cast(ubyte)(sum >> 8);
        buffer[8 + payload.length] = cast(ubyte)sum;
        return payload.length + 9;
    }
}

// Dongles can concatenate vendor and RTU responses in one UDP datagram.
// Return only a checksum-validated frame at the current boundary.
size_t goodwe_response_length(const(ubyte)[] data) pure
{
    if (data.length < 5)
        return 0;
    bool prefixed = data[0] == 0xAA && data[1] == 0x55;
    if (prefixed && data.length >= 9)
    {
        size_t length = 9 + data[6];
        AA55Message message;
        if (length <= data.length && AA55Message.decode(data[0 .. length], message))
            return length;
    }
    if (data[0] == 0x5A && data[1] == 0x5A && data.length >= 8)
    {
        size_t length = 8 + ((uint(data[4]) << 8) | data[5]);
        GoodWeModuleMessage message;
        if (length <= data.length && GoodWeModuleMessage.decode(data[0 .. length], message))
            return length;
        return 0;
    }
    size_t offset = prefixed ? 2 : 0;
    ubyte function_code = data[offset + 1];
    size_t length = function_code & 0x80 ? 5 : (function_code == 3 || function_code == 4) ? 5 + data[offset + 2] :
        function_code == 6 || function_code == 16 ? 8 : 0;
    if (!length || length + offset > data.length)
        return 0;
    GoodWeModbusMessage message;
    return GoodWeModbusMessage.decode(data[0 .. length + offset], message, prefixed) ? length + offset : 0;
}

unittest
{
    ubyte[18] combined = [0xAA, 0x55, 0x0D, 0xC0, 0x01, 0x9A, 0x02, 0x00, 0x14, 0x02, 0x7D,
        0xF7, 0x03, 0x02, 0x00, 0x00, 0x70, 0x51];
    assert(goodwe_response_length(combined) == 11);
    assert(goodwe_response_length(combined[11 .. $]) == 7);
    assert(goodwe_response_length(combined[0 .. 10]) == 0);
    combined[10] ^= 1;
    assert(goodwe_response_length(combined) == 0);
}

unittest
{
    immutable ubyte[9] request = [0xAA, 0x55, 0xC0, 0x7F, 1, 2, 0, 2, 0x41];
    AA55Message message;
    assert(AA55Message.decode(request, message));
    assert(message.source == 0xC0 && message.destination == 0x7F && message.function_code == 2);
    ubyte[264] buffer;
    assert(message.encode(buffer) == request.length && buffer[0 .. request.length] == request);
    foreach (n; 0 .. request.length)
        assert(!AA55Message.decode(request[0 .. n], message));
    buffer[0 .. request.length] = request;
    buffer[4] = 3;
    assert(!AA55Message.decode(buffer[0 .. request.length], message));
    ubyte[255] payload;
    payload[] = 0xFF;
    message = AA55Message(payload, 0x7F, 0xC0, 3, 0x81);
    assert(message.encode(buffer) == 264);
    assert(AA55Message.decode(buffer, message) && message.payload == payload);
    assert(!AA55Message.decode(buffer[0 .. $ - 1], message));
}

unittest
{
    immutable ubyte[7] raw = [0xF7, 3, 2, 0, 42, 0xF1, 0x8E];
    GoodWeModbusMessage message;
    assert(GoodWeModbusMessage.decode(raw, message));
    const(ubyte)[] values;
    assert(message.read_data(1, values) && values[0] == 0 && values[1] == 42);
    assert(!message.read_data(2, values));
    ubyte[9] wrapped;
    assert(message.encode(wrapped, true) == wrapped.length);
    assert(wrapped[0] == 0xAA && wrapped[1] == 0x55 && wrapped[2 .. $] == raw);
    assert(GoodWeModbusMessage.decode(wrapped, message, true));
    assert(!GoodWeModbusMessage.decode(wrapped, message));
    AA55Message aa55;
    assert(!AA55Message.decode(wrapped, aa55));
    foreach (n; 0 .. wrapped.length)
        assert(!GoodWeModbusMessage.decode(wrapped[0 .. n], message, true));
    wrapped[5] ^= 1;
    assert(!GoodWeModbusMessage.decode(wrapped, message, true));
    immutable ubyte[5] exception = [0xF7, 0x83, 2, 0x20, 0xC3];
    assert(GoodWeModbusMessage.decode(exception, message));
    assert(message.function_code == 0x83 && !message.read_data(1, values));
}


unittest
{
    immutable ubyte[3] payload = [2, 0x12, 0x34];
    GoodWeModbusMessage message = GoodWeModbusMessage(payload[], 0xF7, 4);
    ubyte[9] frame;
    assert(message.encode(frame, true) == frame.length);
    assert(goodwe_response_length(frame) == frame.length);
    assert(goodwe_response_length(frame[2 .. $]) == frame.length - 2);
    foreach (length; 0 .. frame.length)
        assert(goodwe_response_length(frame[0 .. length]) == 0);
    frame[$ - 1] ^= 1;
    assert(goodwe_response_length(frame) == 0);
}

unittest
{
    ubyte[12] frame;
    immutable ubyte[4] payload = [1, 2, 3, 4];
    GoodWeModuleMessage source = GoodWeModuleMessage(payload, 1, 2);
    assert(source.encode(frame) == frame.length);
    GoodWeModuleMessage decoded;
    assert(GoodWeModuleMessage.decode(frame, decoded));
    assert(decoded.family == 2 && decoded.function_code == 1 && decoded.payload == source.payload);
    assert(goodwe_response_length(frame) == frame.length);
    foreach (n; 0 .. frame.length)
        assert(!GoodWeModuleMessage.decode(frame[0 .. n], decoded));
    frame[2] = 3;
    assert(!GoodWeModuleMessage.decode(frame, decoded));
    source.family = 3;
    assert(source.encode(frame) == 0);
}

enum GoodWeCommitFormat : ubyte { none, legacy, spn, prohibited, sequence, peak, reactive, native_mode, load, battery_low745, module_network, module_password, legacy_mode, native_apn, native_alarm_page }

struct GoodWeLegacyModeStep
{
    ubyte[5] payload;
    ubyte length;
    ubyte function_code;
    ubyte control = 3;
}

bool goodwe_legacy_mode_step(ushort mode, ubyte step, out GoodWeLegacyModeStep result) pure
{
    if (mode > 3)
        return false;
    enum Operation { clear, work, offgrid, relay, store, charge }
    Operation operation;
    if (mode == 3)
    {
        if (step != 0) return false;
        operation = Operation.work;
    }
    else if (mode == 0)
    {
        if (step > 2) return false;
        operation = step == 0 ? Operation.clear : step == 1 ? Operation.work : Operation.offgrid;
    }
    else if (mode == 1)
    {
        if (step > 4) return false;
        operation = step == 0 ? Operation.clear : step == 1 ? Operation.relay : step == 2 ? Operation.store :
            step == 3 ? Operation.offgrid : Operation.work;
    }
    else
    {
        if (step > 3) return false;
        operation = step == 0 ? Operation.clear : step == 1 ? Operation.offgrid : step == 2 ? Operation.charge : Operation.work;
    }
    result = GoodWeLegacyModeStep.init;
    result.length = 1;
    final switch (operation)
    {
        case Operation.clear:
            result.control = 2;
            result.function_code = 0x39;
            result.length = 5;
            result.payload[0] = 7;
            result.payload[2] = result.payload[4] = 1;
            break;
        case Operation.work:
            result.function_code = 0x59;
            result.payload[0] = cast(ubyte)mode;
            break;
        case Operation.offgrid:
            result.function_code = 0x36;
            result.payload[0] = mode == 1 ? 1 : 0;
            break;
        case Operation.relay:
            result.function_code = 0x27;
            result.length = 2;
            result.payload[1] = 0x30;
            break;
        case Operation.store:
            result.function_code = 0x26;
            result.payload[0] = 4;
            break;
        case Operation.charge:
            result.function_code = 0x2C;
            result.length = 5;
            result.payload[2] = 23;
            result.payload[3] = 59;
            result.payload[4] = 10;
            break;
    }
    return true;
}

unittest
{
    GoodWeLegacyModeStep step;
    assert(goodwe_legacy_mode_step(0, 0, step) && step.control == 2 && step.payload[0 .. 5] == [7, 0, 1, 0, 1]);
    assert(goodwe_legacy_mode_step(0, 1, step) && step.function_code == 0x59 && step.payload[0] == 0);
    assert(goodwe_legacy_mode_step(0, 2, step) && step.function_code == 0x36);
    assert(goodwe_legacy_mode_step(1, 1, step) && step.function_code == 0x27 && step.payload[0 .. 2] == [0, 48]);
    assert(goodwe_legacy_mode_step(1, 2, step) && step.function_code == 0x26 && step.payload[0] == 4);
    assert(goodwe_legacy_mode_step(1, 3, step) && step.function_code == 0x36 && step.payload[0] == 1);
    assert(goodwe_legacy_mode_step(2, 2, step) && step.payload == [0, 0, 23, 59, 10]);
    assert(goodwe_legacy_mode_step(3, 0, step) && step.function_code == 0x59 && step.payload[0] == 3);
    assert(!goodwe_legacy_mode_step(3, 1, step));
    assert(!goodwe_legacy_mode_step(4, 0, step));
}

struct GoodWeModeStep
{
    ushort address;
    ushort value;
    ubyte count = 1;
}

bool goodwe_native_mode_step(ushort mode, ubyte step, out GoodWeModeStep result) pure
{
    if ((mode != 4 && mode != 5) || step > 3)
        return false;
    if (step == 3)
        result = GoodWeModeStep(47000, mode);
    else
    {
        ubyte operation = mode == 5 ? step : cast(ubyte)((step + 2) % 3);
        switch (operation)
        {
            case 0: result = GoodWeModeStep(47511, 1, 2); break;
            case 1: result = GoodWeModeStep(47591, mode == 5 ? 0x037F : 0xFC7F); break;
            case 2: result = GoodWeModeStep(47612, 0); break;
            default: assert(false);
        }
    }
    return true;
}

unittest
{
    GoodWeModeStep step;
    assert(goodwe_native_mode_step(5, 0, step) && step.address == 47511 && step.count == 2 && step.value == 1);
    assert(goodwe_native_mode_step(5, 1, step) && step.address == 47591 && step.value == 0x037F);
    assert(goodwe_native_mode_step(5, 2, step) && step.address == 47612 && step.value == 0);
    assert(goodwe_native_mode_step(4, 0, step) && step.address == 47612 && step.value == 0);
    assert(goodwe_native_mode_step(4, 1, step) && step.address == 47511 && step.count == 2);
    assert(goodwe_native_mode_step(4, 2, step) && step.address == 47591 && step.value == 0xFC7F);
    assert(goodwe_native_mode_step(4, 3, step) && step.address == 47000 && step.value == 4);
    assert(!goodwe_native_mode_step(7, 0, step));
    assert(!goodwe_native_mode_step(5, 4, step));
}

bool goodwe_ordered_commit(GoodWeCommitFormat format) pure
    => format == GoodWeCommitFormat.sequence || format == GoodWeCommitFormat.reactive || format == GoodWeCommitFormat.native_mode || format == GoodWeCommitFormat.battery_low745 || format == GoodWeCommitFormat.native_alarm_page;

bool goodwe_alarm_page_step(ushort index, ubyte step, out GoodWeModeStep result) pure
{
    result = GoodWeModeStep.init;
    switch (step)
    {
        case 0: result.address = 55316; break;
        case 1: result.address = 47016; result.value = index; break;
        case 2: result.address = 55252; result.count = 65; break;
        case 3: result.address = 47016; break;
        default: return false;
    }
    return true;
}

unittest
{
    GoodWeModeStep step;
    assert(goodwe_alarm_page_step(7, 0, step) && step.address == 55316 && step.count == 1);
    assert(goodwe_alarm_page_step(7, 1, step) && step.address == 47016 && step.value == 7);
    assert(goodwe_alarm_page_step(7, 2, step) && step.address == 55252 && step.count == 65);
    assert(goodwe_alarm_page_step(7, 3, step) && step.address == 47016 && step.count == 1);
    assert(!goodwe_alarm_page_step(7, 4, step));
}

const(char)[] validate_goodwe_battery_low745(const(ubyte)[] data) pure
{
    if (data.length != 28)
        return "low745 selection requires fourteen words";
    ushort[14] words = void;
    foreach (i, ref word; words)
        word = cast(ushort)((uint(data[i * 2]) << 8) | data[i * 2 + 1]);
    if (words[0] != 1)
        return "low745 selection requires single-battery mode";
    if (!words[3] || !words[5] || words[5] > words[3] || words[5] != words[8])
        return "invalid or inconsistent battery voltage limits";
    if (words[7] > 100 || words[9] > 100 || words[10] > words[11] || words[11] > 1000)
        return "invalid battery reserve or forced-charge SOC thresholds";
    return null;
}

const(char)[] validate_goodwe_reactive(const(ubyte)[] words) pure
{
    if (words.length != 8)
        return "reactive selection requires four words";
    uint cos_phi = uint(words[0]) << 8 | words[1];
    uint qu = uint(words[2]) << 8 | words[3];
    uint pf = uint(words[4]) << 8 | words[5];
    int q = cast(short)(uint(words[6]) << 8 | words[7]);
    if (cos_phi > 1 || qu > 1 || (cos_phi && qu))
        return "reactive curves are mutually exclusive";
    if (!((pf >= 1 && pf <= 20) || (pf >= 80 && pf <= 100)) || q < -600 || q > 600)
        return "invalid fixed power factor or reactive fraction";
    if ((cos_phi || qu) ? pf != 100 || q != 0 : pf != 100 && q != 0)
        return "reactive selections are mutually exclusive";
    return null;
}

unittest
{
    ubyte[8] words = [0, 0, 0, 1, 0, 100, 0, 0];
    assert(!validate_goodwe_reactive(words).length);
    words[1] = 1;
    assert(validate_goodwe_reactive(words).length);
    words[3] = 0;
    words[5] = 93;
    assert(validate_goodwe_reactive(words).length);
    words[1] = 0;
    assert(!validate_goodwe_reactive(words).length);
    words[6] = 1;
    words[7] = 119;
    assert(validate_goodwe_reactive(words).length);
    words[5] = 100;
    assert(!validate_goodwe_reactive(words).length);
    words[6] = 2;
    words[7] = 89;
    assert(validate_goodwe_reactive(words).length);
}

unittest
{
    ubyte[12] load = [3, 17, 5, 29, 253, 42, 1, 181, 0, 23, 0, 0];
    assert(!validate_goodwe_schedule(load, GoodWeCommitFormat.load).length);
    load[4] = 254;
    assert(validate_goodwe_schedule(load, GoodWeCommitFormat.load).length);
    load[6 .. 10] = 0;
    assert(!validate_goodwe_schedule(load, GoodWeCommitFormat.load).length);
    load[4] = 249;
    assert(validate_goodwe_schedule(load, GoodWeCommitFormat.load).length);
    assert(goodwe_record_matches(1, goodwe_load_record));
    assert(goodwe_record_matches(253, goodwe_load_record));
    assert(!goodwe_record_matches(249, goodwe_load_record));
    assert(!goodwe_record_matches(7, goodwe_load_record));
}

unittest
{
    ubyte[10] peak = [1, 23, 4, 56, 252, 127, 0xC3, 0x50, 0, 23];
    assert(!validate_goodwe_schedule(peak, GoodWeCommitFormat.peak).length);
    peak[7]++;
    assert(validate_goodwe_schedule(peak, GoodWeCommitFormat.peak).length);
    peak[7]--;
    peak[9] = 101;
    assert(validate_goodwe_schedule(peak, GoodWeCommitFormat.peak).length);
    peak[9] = 23;
    peak[4] = 250;
    assert(validate_goodwe_schedule(peak, GoodWeCommitFormat.peak).length);
}

ubyte schedule_record_type(ubyte flag) pure nothrow @nogc
    => flag < 128 ? flag : cast(ubyte)(255 - flag);

enum goodwe_load_record = 7; // Profile family, not a wire tag.

bool goodwe_record_matches(ubyte flag, ubyte kind) pure
{
    ubyte actual = schedule_record_type(flag);
    return kind == goodwe_load_record ? actual == 1 || actual == 2 : actual == kind;
}

enum GoodWeFieldEncoding : ubyte { raw, csv, length_prefixed, status }

bool goodwe_module_field(const(ubyte)[] payload, GoodWeFieldEncoding encoding, ubyte index,
    out const(ubyte)[] field) pure
{
    field = null;
    if (encoding == GoodWeFieldEncoding.raw || encoding == GoodWeFieldEncoding.status)
    {
        if (index != 0)
            return false;
        field = payload;
        return true;
    }
    for (uint current; ; ++current)
    {
        size_t length;
        if (encoding == GoodWeFieldEncoding.length_prefixed)
        {
            if (!payload.length)
                return false;
            length = payload[0];
            payload = payload[1 .. $];
            if (length > payload.length)
                return false;
        }
        else
        {
            while (length < payload.length && payload[length] != ',')
                ++length;
        }
        if (current == index)
        {
            field = payload[0 .. length];
            return true;
        }
        if (encoding == GoodWeFieldEncoding.csv)
        {
            if (length == payload.length)
                return false;
            ++length;
        }
        payload = payload[length .. $];
    }
}

unittest
{
    const(ubyte)[] field;
    const(ubyte)[] csv = cast(const(ubyte)[])"DHCP,192.168.3.5,255.255.255.0,192.168.3.1,192.168.3.1";
    assert(goodwe_module_field(csv, GoodWeFieldEncoding.csv, 1, field));
    assert(cast(const(char)[])field == "192.168.3.5");
    assert(goodwe_module_field(csv, GoodWeFieldEncoding.csv, 4, field));
    assert(cast(const(char)[])field == "192.168.3.1");
    assert(!goodwe_module_field(csv, GoodWeFieldEncoding.csv, 5, field));
    immutable ubyte[8] prefixed = [3, 'a', 'b', 'c', 0, 2, 'x', 'y'];
    assert(goodwe_module_field(prefixed, GoodWeFieldEncoding.length_prefixed, 0, field) && field == prefixed[1 .. 4]);
    assert(goodwe_module_field(prefixed, GoodWeFieldEncoding.length_prefixed, 1, field) && !field.length);
    assert(goodwe_module_field(prefixed, GoodWeFieldEncoding.length_prefixed, 2, field) && field == prefixed[6 .. 8]);
    assert(!goodwe_module_field(prefixed[0 .. 7], GoodWeFieldEncoding.length_prefixed, 2, field));
    assert(goodwe_module_field(csv, GoodWeFieldEncoding.raw, 0, field) && field == csv);
    assert(!goodwe_module_field(csv, GoodWeFieldEncoding.raw, 1, field));
}

const(char)[] validate_goodwe_schedule(const(ubyte)[] data, GoodWeCommitFormat format = GoodWeCommitFormat.legacy) pure nothrow @nogc
{
    if (format == GoodWeCommitFormat.prohibited)
    {
        if (data.length != 6)
            return "prohibited period requires six bytes";
        if ((data[0] != 0 && data[0] != 255) || data[1] > 127)
            return "invalid prohibited period enable or weekday mask";
        if (data[2] > 23 || data[3] > 59 || data[4] > 23 || data[5] > 59)
            return "invalid prohibited period time";
        if (uint(data[2]) * 60 + data[3] >= uint(data[4]) * 60 + data[5])
            return "prohibited period start must precede end";
        return null;
    }
    if (data.length != (format == GoodWeCommitFormat.peak ? 10 : 12))
        return "invalid schedule record length";
    if (data[0] > 23 || data[1] > 59 || data[2] > 23 || data[3] > 59)
        return "invalid schedule time";
    if (uint(data[0]) * 60 + data[1] >= uint(data[2]) * 60 + data[3])
        return "schedule start must precede end";
    if (format == GoodWeCommitFormat.load)
    {
        if (!goodwe_record_matches(data[4], goodwe_load_record) || data[5] > 127 || data[10] || data[11])
            return "invalid load tag, weekday mask or reserved bytes";
        uint power = (uint(data[6]) << 8) | data[7];
        uint minutes = (uint(data[8]) << 8) | data[9];
        if (power > 10000 || minutes > 1440 || (schedule_record_type(data[4]) == 1 && (power || minutes)))
            return "invalid load rated power or minimum run time";
        return null;
    }
    ubyte disabled = format == GoodWeCommitFormat.peak ? 3 : format == GoodWeCommitFormat.spn ? 6 : 0;
    if (data[4] != disabled && data[4] != cast(ubyte)(255 - disabled))
        return "invalid schedule enable flag";
    if (data[5] > 127)
        return "invalid schedule weekday mask";
    if (format == GoodWeCommitFormat.peak)
    {
        if (data[5] != 127 || ((uint(data[6]) << 8) | data[7]) > 50000 || ((uint(data[8]) << 8) | data[9]) > 100)
            return "invalid peak purchase limit, reserve SOC or weekday mask";
        return null;
    }
    short power = cast(short)((uint(data[6]) << 8) | data[7]);
    ushort soc = cast(ushort)((uint(data[8]) << 8) | data[9]);
    int limit = format == GoodWeCommitFormat.spn ? 1000 : 100;
    if (power < -limit || power > limit)
        return "invalid schedule power";
    if (power < 0 && (soc < 10 || soc > 100))
        return "charge cutoff SOC must be between ten and one hundred";
    if (power >= 0 && soc != 0)
        return "discharge cutoff SOC must be zero";
    ushort months = cast(ushort)((uint(data[10]) << 8) | data[11]);
    if (format == GoodWeCommitFormat.spn && (!months || !data[5]))
        return "SPN schedule requires month and weekday selections";
    if (format == GoodWeCommitFormat.spn ? months > 4095 : months != 0)
        return "invalid schedule month mask or reserved bytes";
    return null;
}
