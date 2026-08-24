module manager.log;

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.meta.nullable;
import urt.string;
import urt.string.ansi : visible_width;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.console.command;
import manager.console.function_command;
import manager.console.live_view;
import manager.console.session;
import manager.plugin;
import manager.syslog;

import router.stream;


struct RetainedLogMessage
{
    Array!(char, 0) data;
    SysTime timestamp;
    uint tag_length;
    uint object_name_length;
    uint message_length;
    uint hostname_length;
    Severity severity;
nothrow @nogc:

    void assign(scope ref const LogMessage msg)
    {
        tag_length = cast(uint)msg.tag.length;
        object_name_length = cast(uint)msg.object_name.length;
        message_length = cast(uint)msg.message.length;
        hostname_length = cast(uint)msg.hostname.length;
        severity = msg.severity;
        timestamp = msg.timestamp;

        data.clear();
        data.reserve(tag_length + object_name_length + message_length + hostname_length);
        data ~= msg.tag;
        data ~= msg.object_name;
        data ~= msg.message;
        data ~= msg.hostname;
    }

    LogMessage message()
    {
        size_t tag_end = tag_length;
        size_t object_end = tag_end + object_name_length;
        size_t message_end = object_end + message_length;
        size_t hostname_end = message_end + hostname_length;
        assert(hostname_end == data.length);

        return LogMessage(severity,
                          data[0 .. tag_end],
                          data[tag_end .. object_end],
                          data[object_end .. message_end],
                          data[message_end .. hostname_end],
                          timestamp);
    }
}

struct LogConsumerHandle
{
    int index = -1;
nothrow @nogc:

    bool valid() const pure
        => index >= 0 && index < LogModule.max_consumers;
}

private struct StoredLogMessage
{
    RetainedLogMessage message;
    StoredLogMessage* previous;
    StoredLogMessage* next;
    void* source;
    uint pending;
    bool historical;
}

private struct LogHistoryCursor
{
private:
    void* record;
}

private struct LogConsumerSlot
{
    LogFilter filter;
    StoredLogMessage* cursor;
    StoredLogMessage* current;
    bool active;
}


class LogModule : Module
{
    mixin DeclareModule!"log";
nothrow @nogc:

    enum max_consumers = 16;
    version (Tiny)
    {
        enum delivery_queue_size = 32;
        enum max_history_messages = 32;
        enum default_history_messages = 0;
    }
    else
    {
        enum delivery_queue_size = 128;
        enum max_history_messages = 1024;
        enum default_history_messages = max_history_messages;
    }

    override void init()
    {
        g_app.console.register_command("/log", Command(&log_desc!("emergency", Severity.emergency)));
        g_app.console.register_command("/log", Command(&log_desc!("alert", Severity.alert)));
        g_app.console.register_command("/log", Command(&log_desc!("critical", Severity.critical)));
        g_app.console.register_command("/log", Command(&log_desc!("error", Severity.error)));
        g_app.console.register_command("/log", Command(&log_desc!("warning", Severity.warning)));
        g_app.console.register_command("/log", Command(&log_desc!("notice", Severity.notice)));
        g_app.console.register_command("/log", Command(&log_desc!("info", Severity.info)));
        g_app.console.register_command("/log", Command(&log_desc!("debug", Severity.debug_)));
        g_app.console.register_command("/log", Command(&log_desc!("trace", Severity.trace)));
        g_app.console.register_command!(log_print, "print")("/log", this);
        g_app.console.register_command!(history_get, "get")("/log/history", this);
        g_app.console.register_command!(history_set, "set")("/log/history", this);
        g_app.console.register_command!(history_clear, "clear")("/log/history", this);
        g_app.register_enum!LogFormat();
        g_app.register_enum!LogLineEnding();
        g_app.console.register_collection!LogSink();

        resize_history(_history_limit);
        _ingress_sink = register_log_sink(&ingress, cast(void*)this, LogFilter(Severity.trace));
        recalc_ingress_filter();
    }

    override void update()
    {
        Collection!LogSink().update_all();
        trim_history();
    }

    override void deinit()
    {
        if (_ingress_sink.valid)
        {
            unregister_log_sink(_ingress_sink);
            _ingress_sink = LogSinkHandle.init;
        }
        while (_records_head)
        {
            StoredLogMessage* next = _records_head.next;
            free(_records_head);
            _records_head = next;
        }
        _records_tail = null;
        _history_head = null;
        _history_count = 0;
        _delivery_count = 0;
        foreach (ref consumer; _consumers)
            consumer = LogConsumerSlot.init;
    }

    LogConsumerHandle register_consumer(LogFilter filter)
    {
        foreach (i, ref consumer; _consumers)
        {
            if (consumer.active)
                continue;

            consumer.filter = filter;
            consumer.active = true;
            recalc_ingress_filter();

            retire_bootstrap_log_sink();

            return LogConsumerHandle(cast(int)i);
        }
        return LogConsumerHandle.init;
    }

    void unregister_consumer(LogConsumerHandle handle)
    {
        if (!handle.valid || !_consumers[handle.index].active)
            return;

        uint bit = uint(1) << handle.index;
        StoredLogMessage* record = _records_head;
        while (record)
        {
            StoredLogMessage* next = record.next;
            if (record.pending & bit)
            {
                record.pending &= ~bit;
                if (!record.pending)
                {
                    record.source = null;
                    --_delivery_count;
                    release(record);
                }
            }
            record = next;
        }
        _consumers[handle.index] = LogConsumerSlot.init;
        recalc_ingress_filter();
    }

    void set_consumer_filter(LogConsumerHandle handle, LogFilter filter)
    {
        if (!handle.valid || !_consumers[handle.index].active)
            return;
        _consumers[handle.index].filter = filter;
        recalc_ingress_filter();
    }

    bool next_message(LogConsumerHandle handle, out LogMessage msg, out void* source)
    {
        if (!handle.valid || !_consumers[handle.index].active)
            return false;

        ref consumer = _consumers[handle.index];
        StoredLogMessage* record = consumer.current;
        uint bit = uint(1) << handle.index;
        if (!record)
        {
            record = consumer.cursor;
            while (record && !(record.pending & bit))
                record = record.next;
            consumer.cursor = record;
        }
        if (!record)
            return false;

        consumer.current = record;
        msg = record.message.message();
        source = record.source;
        return true;
    }

    bool next_message(LogConsumerHandle handle, out LogMessage msg)
    {
        void* source;
        return next_message(handle, msg, source);
    }

    void source(void* value)
    {
        _source = value;
    }

    void set_max_severity(Severity severity)
    {
        _global_max_severity = severity;
        recalc_ingress_filter();
    }

    void acknowledge(LogConsumerHandle handle)
    {
        if (!handle.valid || !_consumers[handle.index].active)
            return;

        ref consumer = _consumers[handle.index];
        StoredLogMessage* record = consumer.current;
        if (!record)
            return;

        uint bit = uint(1) << handle.index;
        assert(record.pending & bit);
        StoredLogMessage* next = record.next;
        record.pending &= ~bit;
        consumer.current = null;
        consumer.cursor = next;
        if (!record.pending)
        {
            record.source = null;
            --_delivery_count;
            release(record);
        }
    }

    bool history_enabled() const pure
        => _history_limit > 0;

    uint history_count() const pure
        => _history_count;

    private bool next_history(ref LogHistoryCursor cursor, out LogMessage msg)
    {
        StoredLogMessage* record = cursor.record
            ? (cast(StoredLogMessage*)cursor.record).next : _history_head;
        while (record && !record.historical)
            record = record.next;
        if (!record)
            return false;
        cursor.record = record;
        msg = record.message.message();
        return true;
    }

    void history_get(Session session)
    {
        session.write_line("max-messages=", _history_limit,
                           " max-age=", _history_max_age,
                           " max-severity=", severity_names[_history_max_severity],
                           " tag=", _history_tag,
                           " retained=", _history_count,
                           " delivery-queued=", _delivery_count,
                           " delivery-dropped=", _delivery_dropped);
    }

    void history_set(Session, Nullable!uint max_messages, Nullable!Duration max_age,
                     Nullable!Severity max_severity, Nullable!(const(char)[]) tag)
    {
        if (max_messages)
            resize_history(max_messages.value < max_history_messages
                ? max_messages.value : max_history_messages);
        if (max_age)
            _history_max_age = max_age.value;
        if (max_severity)
            _history_max_severity = max_severity.value;
        if (tag)
            _history_tag = tag.value.make_string();

        trim_history();
        recalc_ingress_filter();
    }

    void history_clear(Session)
    {
        clear_history();
    }

private:
    LogConsumerSlot[max_consumers] _consumers;
    StoredLogMessage* _records_head;
    StoredLogMessage* _records_tail;
    StoredLogMessage* _history_head;
    LogSinkHandle _ingress_sink;
    String _history_tag;
    Duration _history_max_age;
    void* _source;
    uint _delivery_count;
    uint _delivery_dropped;
    uint _history_count;
    uint _history_limit = default_history_messages;
    Severity _history_max_severity = Severity.info;
    Severity _global_max_severity = Severity.trace;

    static void ingress(void* context, scope ref const LogMessage msg)
    {
        (cast(LogModule)context).enqueue(msg);
    }

    void enqueue(scope ref const LogMessage msg)
    {
        uint pending;
        foreach (i, ref consumer; _consumers)
        {
            if (!consumer.active)
                continue;
            if (!matches_filter(msg, consumer.filter))
                continue;
            pending |= uint(1) << i;
        }
        if (pending && _delivery_count == delivery_queue_size)
        {
            pending = 0;
            ++_delivery_dropped;
        }

        bool historical = _history_limit && matches_history(msg);
        if (!pending && !historical)
            return;

        StoredLogMessage* record = alloc!StoredLogMessage();
        if (!record)
        {
            // Can't report the failure: reporting logs, and logging allocates down this path.
            ++_delivery_dropped;
            return;
        }
        record.message.assign(msg);
        record.source = pending ? _source : null;
        record.pending = pending;
        record.historical = historical;
        record.previous = _records_tail;
        if (_records_tail)
            _records_tail.next = record;
        else
            _records_head = record;
        _records_tail = record;

        if (pending)
        {
            ++_delivery_count;
            foreach (i, ref consumer; _consumers)
            {
                uint bit = uint(1) << i;
                if ((pending & bit) && !consumer.current && !consumer.cursor)
                    consumer.cursor = record;
            }
        }
        if (historical)
        {
            if (!_history_head)
                _history_head = record;
            ++_history_count;
            trim_history();
        }
    }

    void release(StoredLogMessage* record)
    {
        if (record.pending || record.historical)
            return;

        foreach (ref consumer; _consumers)
        {
            if (consumer.cursor is record)
                consumer.cursor = record.next;
            if (consumer.current is record)
                consumer.current = null;
        }
        if (record.previous)
            record.previous.next = record.next;
        else
            _records_head = record.next;
        if (record.next)
            record.next.previous = record.previous;
        else
            _records_tail = record.previous;
        free(record);
    }

    void recalc_ingress_filter()
    {
        Severity max_severity = Severity.emergency;
        bool enabled;
        if (_history_limit)
        {
            enabled = true;
            max_severity = _history_max_severity;
        }
        foreach (ref consumer; _consumers)
        {
            if (!consumer.active)
                continue;
            enabled = true;
            if (consumer.filter.max_severity > max_severity)
                max_severity = consumer.filter.max_severity;
        }
        if (_ingress_sink.valid)
        {
            if (max_severity > _global_max_severity)
                max_severity = _global_max_severity;
            set_sink_filter(_ingress_sink, LogFilter(max_severity));
            set_sink_enabled(_ingress_sink, enabled);
        }
    }

    bool matches_history(scope ref const LogMessage msg)
    {
        if (msg.severity > _history_max_severity)
            return false;
        return _history_tag.length == 0 || msg.tag.startsWith(_history_tag[]);
    }

    void trim_history()
    {
        while (_history_count > _history_limit)
            drop_oldest_history();

        bool expire = _history_max_age > Duration.zero;
        SysTime cutoff;
        if (expire)
            cutoff = getSysTime() - _history_max_age;

        StoredLogMessage* record = _history_head;
        while (record)
        {
            StoredLogMessage* next = next_historical(record.next);
            LogMessage msg = record.message.message();
            if (!matches_history(msg) || (expire && msg.timestamp < cutoff))
                drop_history(record);
            record = next;
        }
    }

    void drop_oldest_history()
    {
        assert(_history_head && _history_head.historical);
        drop_history(_history_head);
    }

    void drop_history(StoredLogMessage* record)
    {
        assert(record && record.historical);
        if (_history_head is record)
            _history_head = next_historical(record.next);
        record.historical = false;
        --_history_count;
        release(record);
    }

    StoredLogMessage* next_historical(StoredLogMessage* record)
    {
        while (record && !record.historical)
            record = record.next;
        return record;
    }

    void resize_history(uint limit)
    {
        _history_limit = limit;
        trim_history();
    }

    void clear_history()
    {
        while (_history_count)
            drop_oldest_history();
        _history_head = null;
    }
}

private bool matches_filter(scope ref const LogMessage msg, scope ref const LogFilter filter) nothrow @nogc
{
    if (msg.severity > filter.max_severity)
        return false;
    return filter.tag_prefix.length == 0 || msg.tag.startsWith(filter.tag_prefix);
}


nothrow @nogc:


enum default_log_sink_name = "default";


enum LogFormat : ubyte
{
    text,
    syslog,
}

enum LogLineEnding : ubyte
{
    lf,
    crlf,
}


class LogSink : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("format", format),
                                 Prop!("line-ending", line_ending),
                                 Prop!("max-severity", max_severity),
                                 Prop!("tag", tag));
nothrow @nogc:

    enum type_name = "log-sink";
    enum path = "/log/sink";
    enum collection_id = CollectionType.log_sink;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!LogSink, id, flags);
    }

    final inout(Stream) stream() inout pure
        => _stream;
    final void stream(Stream value)
    {
        if (_stream is value)
            return;
        unsubscribe();
        _stream = value;
        mark_set!(typeof(this), "stream")();
        restart();
    }

    final LogFormat format() const pure
        => _format;
    final void format(LogFormat value)
    {
        if (_format == value)
            return;
        _format = value;
        mark_set!(typeof(this), "format")();
    }

    final LogLineEnding line_ending() const pure
        => _line_ending;
    final void line_ending(LogLineEnding value)
    {
        if (_line_ending == value)
            return;
        _line_ending = value;
        mark_set!(typeof(this), "line-ending")();
    }

    final Severity max_severity() const pure
        => _max_severity;
    final void max_severity(Severity value)
    {
        if (_max_severity == value)
            return;
        _max_severity = value;
        mark_set!(typeof(this), "max-severity")();
        update_filter();
    }

    final ref const(String) tag() const pure
        => _tag;
    final void tag(String value)
    {
        if (_tag == value)
            return;
        _tag = value.move;
        mark_set!(typeof(this), "tag")();
        update_filter();
    }

    override bool validate() const pure
        => _stream !is null;

    override CompletionStatus startup()
    {
        Stream s = _stream;
        if (!s || !s.running)
            return CompletionStatus.continue_;

        s.subscribe(&stream_state_change);
        _subscribed = true;
        _consumer = get_module!LogModule.register_consumer(filter());
        if (!_consumer.valid)
        {
            unsubscribe();
            return CompletionStatus.error;
        }
        retire_bootstrap_log_sink();
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_consumer.valid)
        {
            get_module!LogModule.unregister_consumer(_consumer);
            _consumer = LogConsumerHandle.init;
        }
        unsubscribe();
        _line.clear();
        _write_pos = 0;
        return CompletionStatus.complete;
    }

    override void update()
    {
        Stream s = _stream;
        if (!s || !s.running)
            return;

        LogModule log_module = get_module!LogModule;
        while (true)
        {
            if (_line.length == 0)
            {
                LogMessage msg;
                if (!log_module.next_message(_consumer, msg))
                    return;
                format_message(msg);
            }

            ptrdiff_t written = s.write(_line[_write_pos .. $]);
            if (written < 0)
            {
                restart();
                return;
            }
            if (written == 0)
                return;
            _write_pos += cast(uint)written;
            if (_write_pos < _line.length)
                return;
            _line.clear();
            _write_pos = 0;
            log_module.acknowledge(_consumer);
        }
    }

private:
    ObjectRef!Stream _stream;
    LogConsumerHandle _consumer;
    String _tag;
    Array!(char, 0) _line;
    uint _write_pos;
    LogFormat _format;
    LogLineEnding _line_ending;
    Severity _max_severity = Severity.info;
    bool _subscribed;

    LogFilter filter() const
    {
        LogFilter f;
        f.max_severity = _max_severity;
        f.tag_prefix = _tag[];
        return f;
    }

    void update_filter()
    {
        if (_consumer.valid)
            get_module!LogModule.set_consumer_filter(_consumer, filter());
    }

    void format_message(scope ref const LogMessage msg)
    {
        _line.clear();
        final switch (_format)
        {
            case LogFormat.text:
                _line ~= format_log_text(msg);
                break;
            case LogFormat.syslog:
                _line ~= format_syslog(msg);
                break;
        }
        if (_format != LogFormat.syslog)
            _line ~= _line_ending == LogLineEnding.crlf ? "\r\n" : "\n";
    }

    void stream_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void unsubscribe()
    {
        if (_subscribed)
        {
            _stream.unsubscribe(&stream_state_change);
            _subscribed = false;
        }
    }
}


__gshared LogSinkHandle _bootstrap_log_sink;

void set_bootstrap_log_sink(LogSinkHandle handle)
{
    _bootstrap_log_sink = handle;
}

void retire_bootstrap_log_sink()
{
    if (_bootstrap_log_sink.valid)
    {
        unregister_log_sink(_bootstrap_log_sink);
        _bootstrap_log_sink = LogSinkHandle.init;
    }
}


const(char)[] format_log_line(scope ref const LogMessage msg)
{
    auto sev = severity_styles[msg.severity];
    enum reset = "\x1b[0m";

    if (msg.tag.length > 0)
    {
        size_t h = 5381;
        foreach (c; msg.tag)
            h = h * 33 + c;
        auto tag_fg = tag_colors[h % tag_colors.length];

        enum tag_width = 12;
        char[tag_width + 1] pad_buf = ' ';
        size_t pad = tag_width > msg.tag.length ? tag_width - msg.tag.length + 1 : 1;

        if (msg.object_name.length > 0)
            return tconcat(sev.badge, ' ', tag_fg, msg.tag, pad_buf[0 .. pad], sev.color, '\'', msg.object_name, "': ", msg.message, reset);
        else
            return tconcat(sev.badge, ' ', tag_fg, msg.tag, sev.color, pad_buf[0 .. pad], msg.message, reset);
    }
    else
        return tconcat(sev.badge, ' ', sev.color, msg.message, reset);
}

const(char)[] format_log_text(scope ref const LogMessage msg)
{
    const(char)[] severity = severity_names[msg.severity];
    if (msg.tag.length > 0)
    {
        if (msg.object_name.length > 0)
            return tconcat('[', severity, "] ", msg.tag, " '", msg.object_name, "': ", msg.message);
        return tconcat('[', severity, "] ", msg.tag, ": ", msg.message);
    }
    return tconcat('[', severity, "] ", msg.message);
}

const(char)[] format_log_for_session(scope ref const LogMessage msg, ClientFeatures features)
{
    if (features & ClientFeatures.fullcolour)
        return format_log_line(msg);
    return format_log_text(msg);
}


@TabComplete(&log_print_suggest)
CommandState log_print(Session session, Nullable!Severity level, Nullable!(const(char)[]) tag,
                       Nullable!(const(char)[]) match, Nullable!uint max, const(Variant)[] args)
{
    LogFilter filter;
    filter.max_severity = level ? level.value : Severity.trace;
    if (tag)
        filter.tag_prefix = tag.value;

    bool stream;
    foreach (arg; args)
    {
        const(char)[] option = arg.asString();
        if (option == "--stream")
            stream = true;
        else
        {
            session.write_line("Unknown option '", option, "'");
            return null;
        }
    }

    uint limit = max ? max.value : LogFollowState.default_max_messages;
    if (limit == 0)
        limit = 1;
    if (limit > LogFollowState.max_messages)
        limit = LogFollowState.max_messages;
    return alloc!LogFollowState(session, filter, match ? match.value : null, limit, stream);
}

Array!String log_print_suggest(bool is_value, const(char)[] name, const(char)[])
{
    Array!String result;
    if (!is_value && "--stream".startsWith(name))
        result ~= StringLit!"--stream";
    return result;
}


private:


struct SeverityStyle { string badge, color; }

immutable SeverityStyle[9] severity_styles = [
    SeverityStyle("\x1b[5;1;97;101m ! \x1b[0m", "\x1b[1;91m"),  // emergency
    SeverityStyle("\x1b[1;97;101m A \x1b[0m",   "\x1b[91m"),    // alert
    SeverityStyle("\x1b[1;97;41m C \x1b[0m",    "\x1b[91m"),    // critical
    SeverityStyle("\x1b[97;41m E \x1b[0m",      "\x1b[31m"),    // error
    SeverityStyle("\x1b[30;43m W \x1b[0m",      "\x1b[33m"),    // warning
    SeverityStyle("\x1b[30;46m N \x1b[0m",      "\x1b[36m"),    // notice
    SeverityStyle("\x1b[7m I \x1b[0m",          "\x1b[0m"),     // info
    SeverityStyle("\x1b[97;100m D \x1b[0m",     "\x1b[90m"),    // debug
    SeverityStyle("\x1b[3;37;100m T \x1b[0m",   "\x1b[3;90m"),  // trace
];

immutable string[16] tag_colors = [
    "\x1b[38;2;220;100;100m",  "\x1b[38;2;220;160;100m",
    "\x1b[38;2;200;200;100m",  "\x1b[38;2;130;200;100m",
    "\x1b[38;2;100;200;100m",  "\x1b[38;2;100;200;150m",
    "\x1b[38;2;100;200;200m",  "\x1b[38;2;100;150;220m",
    "\x1b[38;2;100;100;220m",  "\x1b[38;2;150;100;220m",
    "\x1b[38;2;200;100;200m",  "\x1b[38;2;220;100;150m",
    "\x1b[38;2;190;130;80m",   "\x1b[38;2;100;190;190m",
    "\x1b[38;2;190;100;190m",  "\x1b[38;2;170;190;100m",
];

class LogFollowState : LiveViewState
{
nothrow @nogc:

    enum default_max_messages = 256;
    enum max_messages = 1024;

    this(Session session, LogFilter filter, const(char)[] match, uint limit, bool stream)
    {
        super(session, null, LiveViewMode.auto_);
        assert(limit > 0 && limit <= max_messages);
        _log_module = get_module!LogModule;
        _tag = filter.tag_prefix.make_string();
        _match = match.make_string();
        filter.tag_prefix = _tag[];
        _filter = filter;
        _limit = limit;
        _stream = stream;
        _follow = true;

        if (_log_module.history_enabled)
        {
            LogHistoryCursor cursor;
            LogMessage msg;
            while (_log_module.next_history(cursor, msg))
            {
                if (matches(msg))
                    push(msg);
            }
        }
        if (_stream)
        {
            foreach (i; 0 .. _count)
            {
                LogMessage msg;
                if (get_message(i, msg))
                    write_stream_message(msg);
            }
            _stream_ready = true;
        }
        _consumer = _log_module.register_consumer(filter);
    }

    ~this()
    {
        close_consumer();
    }

    override CommandCompletionState update()
    {
        if (_stream)
        {
            if (_stream_cancelled)
            {
                close_consumer();
                return CommandCompletionState.cancelled;
            }

            char[64] input = void;
            ptrdiff_t count = session.read_input(input[]);
            if (count > 0)
            {
                foreach (c; input[0 .. count])
                {
                    if (c == 'q' || c == '\x03')
                    {
                        close_consumer();
                        return CommandCompletionState.finished;
                    }
                }
            }

            poll();
            return CommandCompletionState.in_progress;
        }

        CommandCompletionState state = super.update();
        if (state >= CommandCompletionState.finished)
            close_consumer();
        return state;
    }

    override void request_cancel()
    {
        if (_stream)
            _stream_cancelled = true;
        else
            super.request_cancel();
    }

    override uint content_height()
    {
        uint w = session.width();
        if (w == 0)
            w = 80;
        uint total = 0;
        foreach (i; 0 .. _count)
        {
            LogMessage msg;
            if (!get_message(i, msg))
                continue;
            const(char)[] line = format_log_for_session(msg, session.features);
            uint visible = cast(uint)visible_width(line);
            total += visible == 0 ? 1 : (visible + w - 1) / w;
        }
        return total;
    }

    override void render_content(uint offset, uint count, uint width)
    {
        if (width == 0) width = 80;

        // Find which logical entry corresponds to physical row 'offset'
        uint phys = 0;
        uint src = 0;
        uint sub_offset = 0;
        while (src < _count && phys < offset)
        {
            LogMessage msg;
            if (!get_message(src, msg))
            {
                ++src;
                continue;
            }
            const(char)[] line = format_log_for_session(msg, session.features);
            uint visible = cast(uint)visible_width(line);
            uint rows = visible == 0 ? 1 : (visible + width - 1) / width;
            if (phys + rows > offset)
            {
                sub_offset = offset - phys;
                phys = offset;
                break;
            }
            phys += rows;
            ++src;
        }

        uint drawn = 0;
        while (drawn < count && src < _count)
        {
            LogMessage msg;
            if (!get_message(src, msg))
            {
                ++src;
                continue;
            }
            const(char)[] line = format_log_for_session(msg, session.features);

            uint visible = cast(uint)visible_width(line);
            uint rows = visible == 0 ? 1 : (visible + width - 1) / width;

            // For wrapped lines, we need to emit full line and let terminal wrap,
            // but count physical rows used
            if (sub_offset == 0 && drawn + rows <= count)
            {
                session.write_output("\r", false);
                session.write_output(line, false);
                session.write_output("\x1b[K\r\n", false);
                drawn += rows;
            }
            else
            {
                // Partial line (scrolled into middle of a wrapped entry)
                // Emit the visible portion starting from sub_offset
                uint start_col = sub_offset * width;
                uint remaining_rows = rows - sub_offset;
                if (remaining_rows > count - drawn)
                    remaining_rows = count - drawn;

                session.write_output("\r", false);
                import urt.string.ansi : visible_slice;
                char[512] slice_buf = void;
                const(char)[] segment = line.visible_slice(slice_buf, start_col, start_col + width);
                session.write_output(segment, false);
                session.write_output("\x1b[K\r\n", false);
                drawn += remaining_rows;
                sub_offset = 0;
            }
            ++src;
        }

        while (drawn < count)
        {
            session.write_output("\x1b[K\r\n", false);
            ++drawn;
        }
    }

    override const(char)[] status_text()
    {
        if (_dropped)
            return tconcat(_count, " log entries, ", _dropped, " older entries dropped");
        return tconcat(_count, " log entries");
    }

protected:
    override void poll()
    {
        LogMessage msg;
        while (_log_module.next_message(_consumer, msg))
        {
            if (matches(msg))
                push(msg);
            _log_module.acknowledge(_consumer);
        }
    }

private:
    LogModule _log_module;
    LogConsumerHandle _consumer;
    Array!RetainedLogMessage _messages;
    String _tag;
    String _match;
    LogFilter _filter;
    uint _head;
    uint _count;
    uint _dropped;
    uint _limit;
    bool _stream;
    bool _stream_ready;
    bool _stream_cancelled;

    bool matches(scope ref const LogMessage msg)
    {
        if (!matches_filter(msg, _filter))
            return false;
        if (_match.length == 0)
            return true;

        import urt.string : contains_i;
        return msg.message.contains_i(_match[]) ||
               msg.tag.contains_i(_match[]) ||
               msg.object_name.contains_i(_match[]) ||
               severity_names[msg.severity].contains_i(_match[]);
    }

    void push(scope ref const LogMessage msg)
    {
        uint slot;
        if (_count == _limit)
        {
            slot = _head;
            _messages[slot].data.clear();
            _head = (_head + 1) % _limit;
            ++_dropped;
        }
        else
        {
            _messages ~= RetainedLogMessage.init;
            slot = _count;
            ++_count;
        }
        _messages[slot].assign(msg);
        if (_stream_ready)
            write_stream_message(msg);
        else if (!_stream)
            request_redraw();
    }

    bool get_message(uint index, out LogMessage msg)
    {
        if (index >= _count)
            return false;
        msg = _messages[(_head + index) % _limit].message();
        return true;
    }

    void write_stream_message(scope ref const LogMessage msg)
    {
        session.write_output(format_log_for_session(msg, session.features), false);
        session.write_output("\r\n", false);
    }

    void close_consumer()
    {
        if (!_consumer.valid)
            return;
        _log_module.unregister_consumer(_consumer);
        _consumer = LogConsumerHandle.init;
    }
}


template log_desc(string name, Severity severity)
{
    static immutable CommandClass log_class = {
        exec: &log_exec!severity,
    };

    static immutable CommandDesc log_desc = {
        cls: &log_class,
        name: StringLit!name,
        help_text: StringLit!("Write a message to the log at this severity.\nUsage: " ~ name ~ " <message>"),
    };
}

CommandState log_exec(Severity severity)(ref Command, Session session, Scope*, const Variant[] args, const NamedArgument[] named_args, out Variant result)
{
    if (args.length == 0 || args.length > 1)
    {
        session.write_line("/log command expected string argument");
        return null;
    }

    write_log(severity, "console", null, args[0]);
    return null;
}


unittest
{
    char[5] source = "hello";
    LogMessage input = LogMessage(Severity.warning, "test", "object", source[], "host", SysTime(123));

    RetainedLogMessage retained;
    retained.assign(input);
    source[] = "xxxxx";

    LogMessage restored = retained.message();
    assert(restored.severity == Severity.warning);
    assert(restored.tag == "test");
    assert(restored.object_name == "object");
    assert(restored.message == "hello");
    assert(restored.hostname == "host");
    assert(restored.timestamp == SysTime(123));

    const(char)[] plain = format_log_for_session(restored, ClientFeatures.vt100);
    assert(plain == "[Warning] test 'object': hello");

    const(char)[] decorated = format_log_for_session(restored, ClientFeatures.xterm);
    assert(decorated.contains("\x1b["));

    auto module_ = alloc!LogModule(null);
    scope (exit)
    {
        module_.deinit();
        free(module_);
    }
    module_.resize_history(2);

    LogFilter all;
    all.max_severity = Severity.trace;
    LogConsumerHandle first = module_.register_consumer(all);
    LogConsumerHandle second = module_.register_consumer(all);
    assert(first.valid && second.valid);

    char[6] queued_text = "queued";
    LogMessage queued = LogMessage(Severity.info, "queue", null, queued_text[], "host", SysTime(456));
    module_.enqueue(queued);
    queued_text[] = "xxxxxx";
    assert(module_._delivery_count == 1);
    assert(module_.history_count == 1);

    LogMessage delivered;
    assert(module_.next_message(first, delivered));
    assert(delivered.message == "queued");
    module_.acknowledge(first);
    assert(module_._delivery_count == 1);

    assert(module_.next_message(second, delivered));
    assert(delivered.message == "queued");
    module_.acknowledge(second);
    assert(module_._delivery_count == 0);

    queued.message = "release";
    module_.enqueue(queued);
    assert(module_.next_message(first, delivered));
    module_.unregister_consumer(second);
    assert(module_._delivery_count == 1);
    module_.acknowledge(first);
    assert(module_._delivery_count == 0);

    module_.resize_history(1);
    assert(module_.history_count == 1);
    LogHistoryCursor cursor;
    assert(module_.next_history(cursor, delivered));
    assert(delivered.message == "release");

    module_.unregister_consumer(first);
    queued.message = "history-only";
    module_.enqueue(queued);
    assert(module_._delivery_count == 0);
    cursor = LogHistoryCursor.init;
    assert(module_.next_history(cursor, delivered));
    assert(delivered.message == "history-only");

    module_.resize_history(2);
    queued.severity = Severity.error;
    queued.message = "history-error";
    module_.enqueue(queued);
    assert(module_.history_count == 2);
    module_._history_max_severity = Severity.warning;
    module_.trim_history();
    assert(module_.history_count == 1);
    cursor = LogHistoryCursor.init;
    assert(module_.next_history(cursor, delivered));
    assert(delivered.message == "history-error");

    module_.clear_history();
    assert(module_._records_head is null);

    module_.resize_history(0);
    queued.severity = Severity.info;
    first = module_.register_consumer(all);
    foreach (i; 0 .. LogModule.delivery_queue_size + 1)
    {
        queued.timestamp = SysTime(i);
        module_.enqueue(queued);
    }
    assert(module_._delivery_count == LogModule.delivery_queue_size);
    assert(module_._delivery_dropped == 1);
    module_.unregister_consumer(first);
    assert(module_._delivery_count == 0);
    assert(module_._records_head is null);
}
