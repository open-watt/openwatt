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
import manager.plugin;

public import router.status;

// package modules...
public static import router.stream.bridge;
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
nothrow @nogc:

    this(const CollectionTypeInfo* type_info, String name, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(type_info, name.move, flags);

        assert(!get_module!StreamModule.streams.exists(this.name[]), "HOW DID THIS HAPPEN?");
        get_module!StreamModule.streams.add(this);

        this._options = options;
    }

    this(String name, const(char)[] type, StreamOptions options)
    {
        super(name.move, type);

        get_module!StreamModule.streams.add(this);

        this._options = options;
    }

    ~this()
    {
        // TODO: should we check if it's already disconnected before calling this?
        disconnect();

        set_log_file(null);

        get_module!StreamModule.streams.remove(this);
    }

    static const(char)[] validate_name(const(char)[] name)
    {
        import urt.mem.temp;
        if (get_module!StreamModule.streams.exists(name))
            return tconcat("Stream with name '", name[], "' already exists");
        return null;
    }


    // Properties...


    // API...

    ref const(Status) status() const pure
        => _status;

    final void reset_counters() pure
    {
        _status.link_downs = 0;
        _status.send_bytes = 0;
        _status.recv_bytes = 0;
        _status.send_packets = 0;
        _status.recv_packets = 0;
        _status.send_dropped = 0;
        _status.recv_dropped = 0;
    }

    override const(char)[] status_message() const
        => running ? "Running" : super.status_message();

    // TODO: remove public when everything ported to collections...
    override void update()
    {
        assert(_status.link_status == LinkStatus.up, "Stream is not online, it shouldn't be in Running state!");
    }

    override void set_online()
    {
        super.set_online();
        _status.link_status = LinkStatus.up;
        _status.link_status_change_time = getSysTime();
    }

    override void set_offline()
    {
        super.set_offline();
        _status.link_status = LinkStatus.down;
        _status.link_status_change_time = getSysTime();
        ++_status.link_downs;
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
    Status _status;
    StreamOptions _options;
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

    Collection!Stream streams;

    override void init()
    {
        // HACK: Stream collection is not a natural collection, so we'll init it here...
        ref Collection!Stream* c = collection_for!Stream();
        assert(c is null, "Collection has been registered before!");
        c = &streams;
    }
}


private:
