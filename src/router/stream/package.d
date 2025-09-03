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
    None = 0,

    ReverseConnect = 1 << 0, // For TCP connections where remote will initiate connection
    BufferData =     1 << 1, // Buffer read/write data when stream is not ready
    AllowBroadcast = 1 << 2, // Allow broadcast messages
}

abstract class Stream : BaseObject
{
//    __gshared Property[1] Properties = [ Property.create!("running", running)() ];
nothrow @nogc:

    this(const CollectionTypeInfo* typeInfo, String name, ObjectFlags flags = ObjectFlags.None, StreamOptions options = StreamOptions.None)
    {
        super(typeInfo, name.move, flags);

        assert(!getModule!StreamModule.streams.exists(this.name), "HOW DID THIS HAPPEN?");
        getModule!StreamModule.streams.add(this);

        this.options = options;
    }

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

    static const(char)[] validateName(const(char)[] name)
    {
        import urt.mem.temp;
        if (getModule!StreamModule.streams.exists(name))
            return tconcat("Stream with name '", name[], "' already exists");
        return null;
    }


    // Properties...


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

    override const(char)[] statusMessage() const
        => running ? "Running" : super.statusMessage();

    // TODO: remove public when everyting ported to collections...
    override void update()
    {
        assert(_status.linkStatus == Status.Link.Up, "Stream is not online, it shouldn't be in Running state!");
    }

    override void setOnline()
    {
        super.setOnline();
        _status.linkStatus = Status.Link.Up;
        _status.linkStatusChangeTime = getSysTime();
    }

    override void setOffline()
    {
        super.setOffline();
        _status.linkStatus = Status.Link.Down;
        _status.linkStatusChangeTime = getSysTime();
        ++_status.linkDowns;
    }

    // Initiate an on-demand connection
    bool connect()
        => true;

    // Disconnect the stream
    void disconnect()
    {
    }

    abstract const(char)[] remoteName();

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

    Collection!Stream streams;
}


private:
