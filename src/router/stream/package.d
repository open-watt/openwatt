module router.stream;

import urt.conv;
import urt.lifetime;
import urt.map;
import urt.mem.string;
import urt.meta.nullable;
import urt.string;
import urt.string.format;
import urt.time;

import manager.console;
import manager.plugin;


//public import router.stream.bridge;
//public import router.stream.serial;
//public import router.stream.tcp;
//public import router.stream.udp;


enum StreamOptions
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

struct StreamStatus
{
    MonoTime linkStatusChangeTime;
    bool linkStatus;
    int linkDowns;
    ulong sendBytes;
    ulong recvBytes;
    ulong sendDropped;
    ulong recvDropped;
}

abstract class Stream
{
nothrow @nogc:

    String name;
    CacheString type;

    StreamStatus status;

    this(String name, const(char)[] type, StreamOptions options) nothrow @nogc
    {
        this.name = name.move;
        this.type = type.addString();
        this.options = options;
    }

    ~this()
    {
        // TODO: should we check if it's already disconnected before calling this?
        disconnect();
    }

    // Method to initiate a connection
    abstract bool connect();

    // Method to disconnect the stream
    abstract void disconnect();

    // Check if the stream is connected
    abstract bool connected() nothrow @nogc;

    abstract const(char)[] remoteName();

    abstract void setOpts(StreamOptions options) nothrow @nogc;

    // Read data from the stream
    abstract ptrdiff_t read(void[] buffer) nothrow @nogc;

    // Write data to the stream
    abstract ptrdiff_t write(const void[] data) nothrow @nogc;

    // Return the number of bytes in the read buffer
    abstract ptrdiff_t pending();

    // Flush the receive buffer (return number of bytes destroyed)
    abstract ptrdiff_t flush();

    // Update the stream
    void update()
    {
    }

protected:
    bool live;
    StreamOptions options;

    uint bufferLen = 0;
    void[] sendBuffer;
}

class StreamModule : Plugin
{
    mixin RegisterModule!"stream";

    class Instance : Plugin.Instance
    {
        mixin DeclareInstance;
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

            foreach (stream; streams)
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
            foreach (s; streams)
                if (s.name[] == name[])
                    return s;
            return null;
        }
    }
}


private:
