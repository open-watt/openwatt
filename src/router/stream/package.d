module router.stream;

import urt.conv;
import urt.file;
import urt.lifetime;
import urt.map;
import urt.mem.string;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.console.session;
import manager.plugin;

public import router.status;

// package modules...
public static import router.stream.bridge;
public static import router.stream.console;
public static import router.stream.serial;
public static import router.stream.tcp;
public static import router.stream.udp;

version = SupportLogging;

nothrow @nogc:


enum StreamOptions : ubyte
{
    none = 0,

    reverse_connect = 1 << 0, // For TCP connections where remote will initiate connection
    buffer_data =     1 << 1, // Buffer read/write data when stream is not ready
    allow_broadcast = 1 << 2, // Allow broadcast messages
}

abstract class Stream : BaseObject
{
    __gshared Property[9] Properties = [ Property.create!("last_status_change_time", last_status_change_time, "status")(),
                                         Property.create!("link_status", link_status, "status", "d")(),
                                         Property.create!("link_downs", link_downs, "status")(),
                                         Property.create!("tx_bytes", tx_bytes, "traffic", "d")(),
                                         Property.create!("rx_bytes", rx_bytes, "traffic", "d")(),
                                         Property.create!("tx_rate", tx_rate, "traffic", "d")(),
                                         Property.create!("rx_rate", rx_rate, "traffic", "d")(),
                                         Property.create!("tx_rate_max", tx_rate_max, "traffic")(),
                                         Property.create!("rx_rate_max", rx_rate_max, "traffic")() ];
nothrow @nogc:

    enum type_name = "stream";
    enum collection_id = CollectionType.stream;

    this(const CollectionTypeInfo* type_info, CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(type_info, id, flags);

        this._options = options;
    }

    ~this()
    {
        // TODO: should we check if it's already disconnected before calling this?
        disconnect();

        set_log_file(null);
    }

    // Properties...

    SysTime last_status_change_time() const => _status.link_status_change_time;
    LinkStatus link_status() const => _status.link_status;
    ulong link_downs() const => _status.link_downs;
    ulong tx_bytes() const => _status.tx_bytes;
    ulong rx_bytes() const => _status.rx_bytes;
    ulong tx_rate() const => _status.tx_rate;
    ulong rx_rate() const => _status.rx_rate;
    ulong tx_rate_max() const => _status.tx_rate_max;
    ulong rx_rate_max() const => _status.rx_rate_max;


    // API...

    ref const(StreamStatus) status() const pure
        => _status;

    final void reset_counters() pure
    {
        _status.link_downs = 0;
        _status.tx_bytes = 0;
        _status.rx_bytes = 0;
    }

    override const(char)[] status_message() const
        => running ? "Running" : super.status_message();

    override void update()
    {
        assert(_status.link_status == LinkStatus.up, "Stream is not online, it shouldn't be in Running state!");

        MonoTime now = getTime();
        if ((now - _last_bitrate_sample) >= 1.seconds)
        {
            ulong elapsed_us = (now - _last_bitrate_sample).as!"usecs";
            _status.tx_rate = (_status.tx_bytes - _last_tx_bytes) * 1_000_000 / elapsed_us;
            _status.rx_rate = (_status.rx_bytes - _last_rx_bytes) * 1_000_000 / elapsed_us;

            if (_status.tx_rate > _status.tx_rate_max)
                _status.tx_rate_max = _status.tx_rate;
            if (_status.rx_rate > _status.rx_rate_max)
                _status.rx_rate_max = _status.rx_rate;

            _last_tx_bytes = _status.tx_bytes;
            _last_rx_bytes = _status.rx_bytes;
            _last_bitrate_sample = now;
        }
    }

    override void online()
    {
        _status.link_status = LinkStatus.up;
        _status.link_status_change_time = getSysTime();
        _last_bitrate_sample = getTime();
        _last_tx_bytes = _status.tx_bytes;
        _last_rx_bytes = _status.rx_bytes;
    }

    override void offline()
    {
        _status.link_status = LinkStatus.down;
        _status.link_status_change_time = getSysTime();
        ++_status.link_downs;
        _status.tx_rate = 0;
        _status.rx_rate = 0;
    }

    // Initiate an on-demand connection
    bool connect()
        => true;

    // Disconnect the stream
    void disconnect()
    {
    }

    abstract const(char)[] remote_name();

    // Read data from the stream
    abstract ptrdiff_t read(void[] buffer);

    // Write data to the stream
    abstract ptrdiff_t write(const(void[])[] data...);

    // Return the number of bytes in the read buffer
    abstract ptrdiff_t pending();

    // Flush the receive buffer (return number of bytes destroyed)
    abstract ptrdiff_t flush();

    // Optional terminal side-channel for streams that support terminal semantics
    // (TelnetStream, ConsoleStream, etc.). Returns null for non-terminal streams.
    TerminalChannel* terminal_channel() { return null; }

    void set_log_file(const(char)[] base_filename)
    {
        version (SupportLogging)
        {
            if (_log[0].is_open())
                _log[0].close();
            if (_log[1].is_open())
                _log[1].close();
            _logging = false;
            if (base_filename)
            {
                // TODO: should we not append, and instead bump a number on the end of the filename and write a new one?
                //       probably want to separate the logs for each session...?
                //       and should we disable buffering? kinda slow, but if we crash, we want to know what crashed it, right?
                _log[0].open(tconcat(base_filename, ".tx"), FileOpenMode.WriteAppend, FileOpenFlags.Sequential /+| FileOpenFlags.NoBuffering+/);
                _log[1].open(tconcat(base_filename, ".rx"), FileOpenMode.WriteAppend, FileOpenFlags.Sequential /+| FileOpenFlags.NoBuffering+/);
                _logging = _log[0].is_open() || _log[1].is_open();
            }
        }
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const nothrow @nogc
    {
        if (buffer.length < "stream:".length + name.length)
            return -1; // Not enough space
        return buffer.concat("stream:", name[]).length;
    }

protected:
    StreamStatus _status;
    StreamOptions _options;

    MonoTime _last_bitrate_sample;
    ulong _last_tx_bytes;
    ulong _last_rx_bytes;
    version (SupportLogging)
    {
        bool _logging;
        File[2] _log;
    }
    else
        enum _logging = false;

    uint _buffer_len = 0;
    void[] _send_buffer;

    final void write_to_log(bool rx, const void[] buffer)
    {
        version (SupportLogging)
        {
            if (!_logging || !_log[rx].is_open)
                return;
            size_t written;
            _log[rx].write(buffer, written);
            // TODO: do we want to assert the write was successful? maybe disk full? should probably not crash the app...
//            assert(written == buffer.length, "Failed to write to log file...?");
        }
    }
}

class StreamModule : Module
{
    mixin DeclareModule!"stream";
nothrow @nogc:

    override void pre_init()
    {
        g_app.console.register_collection!Stream("/stream");
    }

    override void pre_update()
    {
        Collection!Stream().update_all();
    }
}


private:
