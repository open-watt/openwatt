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
    None = 0,

    // Should non-blocking be a thing like this? I think it's up to the stream to work out how it wants to operate...
    NonBlocking =    1 << 0, // Non-blocking IO

    ReverseConnect = 1 << 1, // For TCP connections where remote will initiate connection
    OnDemand =       1 << 2, // Only connect on demand
    BufferData =     1 << 3, // Buffer read/write data when stream is not ready
    AllowBroadcast = 1 << 4, // Allow broadcast messages

    // TODO: DELETE THIS ONE, it should be default behaviour!
    KeepAlive =      1 << 2, // Attempt reconnection on connection drops
}

abstract class Stream : BaseObject
{
    __gshared Property[1] Properties = [ Property.create!("running", running)() ];
nothrow @nogc:

    this(String name, const(char)[] type, StreamOptions options)
    {
        super(name.move, type);

        this.options = options;
    }

    ~this()
    {
        // TODO: should we check if it's already disconnected before calling this?
        disconnect();

        setLogFile(null);
    }

    // Properties...

    final bool running() const pure
        => _status.linkStatus == Status.Link.Up;


    // API...

    ref const(Status) status() const pure
        => _status;

    final void resetCounters() pure
    {
        _status.linkDowns = 0;
        _status.sendBytes = 0;
        _status.recvBytes = 0;
        _status.sendPackets = 0;
        _status.recvPackets = 0;
        _status.sendDropped = 0;
        _status.recvDropped = 0;
    }

    override const(char)[] statusMessage() const pure
        => running ? "Running" : super.statusMessage();

    override bool enable(bool enable = true)
    {
        bool wasEnabled = !_disabled;
        if (enable != wasEnabled)
        {
            _status.linkStatusChangeTime = getSysTime();
            _disabled = !enable;
            if (_disabled)
            {
                disconnect();
                debug assert(_status.linkStatus == Status.Link.Down);
//                _status.linkStatus = Status.Link.Down;
                ++_status.linkDowns; // TODO: shoul this be moved to wherever the down is assigned?
            }
        }
        return wasEnabled;
    }

    // Method to initiate a connection
    abstract bool connect();

    // Method to disconnect the stream
    abstract void disconnect();

    abstract const(char)[] remoteName();

    abstract void setOpts(StreamOptions options);

    // Read data from the stream
    abstract ptrdiff_t read(void[] buffer);

    // Write data to the stream
    abstract ptrdiff_t write(const void[] data);

    // Return the number of bytes in the read buffer
    abstract ptrdiff_t pending();

    // Flush the receive buffer (return number of bytes destroyed)
    abstract ptrdiff_t flush();

    void setLogFile(const(char)[] baseFilename)
    {
        version (SupportLogging)
        {
            if (log[0].is_open())
                log[0].close();
            if (log[1].is_open())
                log[1].close();
            logging = false;
            if (baseFilename)
            {
                // TODO: should we not append, and instead bump a number on the end of the filename and write a new one?
                //       probably want to separate the logs for each session...?
                //       and should we disable buffering? kinda slow, but if we crash, we want to know what crashed it, right?
                log[0].open(tconcat(baseFilename, ".tx"), FileOpenMode.WriteAppend, FileOpenFlags.Sequential /+| FileOpenFlags.NoBuffering+/);
                log[1].open(tconcat(baseFilename, ".rx"), FileOpenMode.WriteAppend, FileOpenFlags.Sequential /+| FileOpenFlags.NoBuffering+/);
                logging = log[0].is_open() || log[1].is_open();
            }
        }
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
    {
        if (buffer.length < "stream:".length + name.length)
            return -1; // Not enough space
        return buffer.concat("stream:", name[]).length;
    }

protected:
    Status _status;
    StreamOptions options;
    version (SupportLogging)
    {
        bool logging;
        File[2] log;
    }
    else
        enum logging = false;

    uint bufferLen = 0;
    void[] sendBuffer;

    final void writeToLog(bool rx, const void[] buffer)
    {
        version (SupportLogging)
        {
            if (!logging || !log[rx].is_open)
                return;
            size_t written;
            log[rx].write(buffer, written);
            // TODO: do we want to assert the write was successful? maybe disk full? should probably not crash the app...
//            assert(written == buffer.length, "Failed to write to log file...?");
        }
    }
}

class StreamModule : Module
{
    mixin DeclareModule!"stream";
nothrow @nogc:

    Map!(const(char)[], Stream) streams;

    override void init()
    {
    }

    Stream getStream(const(char)[] name)
    {
        Stream* s = name in streams;
        return s ? *s : null;
    }

    override void preUpdate()
    {
        // TODO: polling is super lame! data connections should be in threads and receive data immediately
        // blocking read's in threads, or a select() loop...

        foreach (stream; streams.values)
            stream.update();
    }

    const(char)[] generateStreamName(const(char)[] prefix)
    {
        if (prefix !in streams)
            return prefix;
        for (size_t i = 0; i < ushort.max; i++)
        {
            const(char)[] name = tconcat(prefix, i);
            if (name !in streams)
                return name;
        }
        return null;
    }

    final void addStream(Stream stream)
    {
        assert(stream.name[] !in streams, "Stream already exists");
        streams[stream.name[]] = stream;
    }

    final void removeStream(Stream stream)
    {
        assert(stream.name[] in streams, "Stream not found");
        streams.remove(stream.name[]);
    }

    final Stream findStream(const(char)[] name)
    {
        foreach (s; streams.values)
            if (s.name[] == name[])
                return s;
        return null;
    }
}


private:
