module driver.esp32.idf_log_bridge;

import urt.log : Severity;

version (NoIDFLog) {}
else version (ESP8266) {}
else version (Espressif) version = ESPIDFLogBridge;

version (ESPIDFLogBridge)
{
    import urt.atomic : atomicLoad, atomicStore, cas, MemoryOrder;
    import urt.driver.esp32.idf_log;
    import urt.log : write_log;
    import urt.mem;
    import urt.time;

    import manager;
    import manager.plugin;
}

nothrow @nogc:


version (ESPIDFLogBridge)
{
class IDFLogBridgeModule : Module
{
    mixin DeclareModule!"esp-idf-log";
nothrow @nogc:

    override void init()
    {
        void[] memory = alloc(LineAssembler.sizeof * max_sources,
                                                 LineAssembler.alignof);
        if (!memory.ptr)
        {
            log.error("Failed to allocate ESP-IDF log assembly buffers");
            return;
        }
        _lines = cast(LineAssembler*)memory.ptr;
        reset_lines();
        atomicStore!(MemoryOrder.relaxed)(_drain_pending, 0u);
        atomicStore!(MemoryOrder.release)(g_bridge, cast(size_t)cast(void*)this);
        idf_log_set_ready_callback(&idf_log_ready);
        _open = idf_log_open();
        if (!_open)
        {
            idf_log_set_ready_callback(null);
            atomicStore!(MemoryOrder.release)(g_bridge, 0);
            log.error("Failed to capture ESP-IDF logs");
        }
    }

    override void deinit()
    {
        if (_open)
            idf_log_close();
        idf_log_set_ready_callback(null);
        atomicStore!(MemoryOrder.release)(g_bridge, 0);
        atomicStore!(MemoryOrder.relaxed)(_drain_pending, 0u);
        _open = false;
        if (_lines)
        {
            free((cast(void*)_lines)[0 .. LineAssembler.sizeof * max_sources]);
            _lines = null;
        }
    }

private:
    enum max_sources = 8;
    enum max_line_length = 512;

    LineAssembler* _lines;
    shared uint _drain_pending;
    uint _activity;
    uint _drop_generation;
    bool _have_drop_generation;
    bool _open;

    void request_drain()
    {
        if (g_app is null || !cas(&_drain_pending, 0u, 1u))
            return;
        MonoTime now = getTime();
        bool queued = g_app.try_post_event(&g_drain_sweep.event, now, EventPriority.bulk);
        if (!queued)
            queued = g_app.try_post_event(&g_drain_sweep.event, now, EventPriority.control);
        if (!queued)
            atomicStore!(MemoryOrder.release)(_drain_pending, 0u);
    }

    void drain(MonoTime)
    {
        atomicStore!(MemoryOrder.release)(_drain_pending, 0u);
        IdfLogChunk chunk = void;
        while (idf_log_receive(chunk))
            consume(chunk);

        uint dropped = idf_log_take_drops();
        if (dropped != 0)
        {
            reset_lines();
            _have_drop_generation = false;
            write_log(Severity.warning, "esp-idf", null, "Capture dropped ", dropped,
                      dropped == 1 ? " log fragment" : " log fragments");
        }
    }

    void consume(scope ref IdfLogChunk chunk)
    {
        if (!_have_drop_generation)
        {
            _drop_generation = chunk.drop_generation;
            _have_drop_generation = true;
        }
        else if (_drop_generation != chunk.drop_generation)
        {
            reset_lines();
            _drop_generation = chunk.drop_generation;
        }

        LineAssembler* line = line_for(chunk.task);
        foreach (c; chunk.text)
        {
            if (c == '\r' || c == '\n')
            {
                emit(*line);
                continue;
            }
            if (line.length < line.data.length)
                line.data[line.length++] = c;
            else
                line.truncated = true;
        }
        if (chunk.truncated)
        {
            line.truncated = true;
            emit(*line);
        }
    }

    LineAssembler* line_for(void* task)
    {
        foreach (ref line; _lines[0 .. max_sources])
        {
            if (line.used && line.task is task)
            {
                line.activity = ++_activity;
                return &line;
            }
        }
        foreach (ref line; _lines[0 .. max_sources])
        {
            if (!line.used || line.length == 0)
                return assign(line, task);
        }

        LineAssembler* oldest = &_lines[0];
        foreach (ref line; _lines[1 .. max_sources])
            if (line.activity < oldest.activity)
                oldest = &line;
        oldest.truncated = true;
        emit(*oldest);
        return assign(*oldest, task);
    }

    LineAssembler* assign(ref LineAssembler line, void* task)
    {
        line.task = task;
        line.length = 0;
        line.activity = ++_activity;
        line.used = true;
        line.truncated = false;
        return &line;
    }

    void emit(ref LineAssembler line)
    {
        if (line.length == 0 && !line.truncated)
            return;

        size_t length = line.length;
        if (line.truncated)
        {
            enum marker = " [truncated]";
            if (length > line.data.length - marker.length)
                length = line.data.length - marker.length;
            line.data[length .. length + marker.length] = marker[];
            length += marker.length;
        }
        ParsedIDFLine parsed = parse_idf_line(line.data[0 .. length]);
        write_log(parsed.severity, "esp-idf", parsed.tag, parsed.message);
        line.length = 0;
        line.truncated = false;
    }

    void reset_lines()
    {
        foreach (ref line; _lines[0 .. max_sources])
        {
            line.task = null;
            line.length = 0;
            line.activity = 0;
            line.used = false;
            line.truncated = false;
        }
    }
}

private:
struct LineAssembler
{
    void* task;
    uint activity;
    ushort length;
    bool used;
    bool truncated;
    char[IDFLogBridgeModule.max_line_length] data = void;
}

__gshared shared(size_t) g_bridge;

struct DrainSweep
{
    void event(MonoTime when) nothrow @nogc
    {
        size_t bridge = atomicLoad!(MemoryOrder.acquire)(g_bridge);
        if (bridge != 0)
            (cast(IDFLogBridgeModule)cast(void*)bridge).drain(when);
    }
}
__gshared DrainSweep g_drain_sweep;

void idf_log_ready()
{
    size_t bridge = atomicLoad!(MemoryOrder.acquire)(g_bridge);
    if (bridge != 0)
        (cast(IDFLogBridgeModule)cast(void*)bridge).request_drain();
}
}


private:
struct ParsedIDFLine
{
    Severity severity;
    const(char)[] tag;
    const(char)[] message;
}

ParsedIDFLine parse_idf_line(const(char)[] input)
{
    const(char)[] line = strip_ansi(input);
    ParsedIDFLine result = { severity: Severity.info, message: line };
    if (line.length < 2 || line[1] != ' ')
        return result;

    switch (line[0])
    {
        case 'E': result.severity = Severity.error; break;
        case 'W': result.severity = Severity.warning; break;
        case 'I': result.severity = Severity.info; break;
        case 'D': result.severity = Severity.debug_; break;
        case 'V': result.severity = Severity.trace; break;
        default: return result;
    }

    line = line[2 .. $];
    if (line.length > 0 && line[0] == '(')
    {
        size_t close;
        for (close = 1; close < line.length && line[close] != ')'; ++close) {}
        if (close < line.length)
        {
            line = line[close + 1 .. $];
            if (line.length > 0 && line[0] == ' ')
                line = line[1 .. $];
        }
    }

    result.message = line;
    for (size_t i; i + 1 < line.length; ++i)
    {
        if (line[i] != ':' || line[i + 1] != ' ')
            continue;
        result.tag = line[0 .. i];
        result.message = line[i + 2 .. $];
        break;
    }
    return result;
}

const(char)[] strip_ansi(const(char)[] input)
{
    const(char)[] line = input;
    while (line.length >= 3 && line[0] == '\x1b' && line[1] == '[')
    {
        size_t end = csi_end(line);
        if (end == 0)
            break;
        line = line[end .. $];
    }
    while (line.length >= 3 && line[$ - 1] >= '@' && line[$ - 1] <= '~')
    {
        size_t start = line.length - 2;
        while (start > 0 && line[start] != '\x1b')
            --start;
        if (line[start] != '\x1b' || start + 1 >= line.length || line[start + 1] != '[')
            break;
        line = line[0 .. start];
    }
    return line;
}

size_t csi_end(const(char)[] text)
{
    for (size_t i = 2; i < text.length; ++i)
        if (text[i] >= '@' && text[i] <= '~')
            return i + 1;
    return 0;
}


unittest
{
    auto v1 = parse_idf_line("E (123) wifi: association failed");
    assert(v1.severity == Severity.error);
    assert(v1.tag == "wifi");
    assert(v1.message == "association failed");

    auto v2 = parse_idf_line("W storage: nearly full");
    assert(v2.severity == Severity.warning);
    assert(v2.tag == "storage");
    assert(v2.message == "nearly full");

    auto coloured = parse_idf_line("\x1b[0;32mI (7) boot: ready\x1b[0m");
    assert(coloured.severity == Severity.info);
    assert(coloured.tag == "boot");
    assert(coloured.message == "ready");

    auto raw = parse_idf_line("raw diagnostic");
    assert(raw.severity == Severity.info);
    assert(raw.tag is null);
    assert(raw.message == "raw diagnostic");
}
