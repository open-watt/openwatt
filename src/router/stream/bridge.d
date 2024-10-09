module router.stream.bridge;

import urt.array;
import urt.log;
import urt.mem;
import urt.string;
import urt.string.format;

import manager.console;
import manager.plugin;

public import router.stream;

class BridgeStream : Stream
{
nothrow @nogc:

    this(String name, StreamOptions options, Stream[] streams...) nothrow @nogc
    {
        import urt.lifetime;

        super(name.move, "bridge", options);

        this.m_streams = streams;
        this.m_remoteName.reserve(60);

        m_remoteName = "bridge[";
        foreach (i, s; streams)
        {
            if (i > 0)
                m_remoteName ~= "|";
            m_remoteName ~= s.remoteName();
        }
        m_remoteName ~= "]";
    }

    override bool connect()
    {
        // should we connect subordinate streams?
        return true;
    }

    override void disconnect()
    {
        // TODO: Should this disconnect subordinate streams?
    }

    override bool connected()
    {
        // what here?
        return true;
    }

    override const(char)[] remoteName()
        => m_remoteName;

    override void setOpts(StreamOptions options)
    {
        this.options = options;
    }

    override ptrdiff_t read(void[] buffer)
    {
        size_t read;
        if (buffer.length < m_inputBuffer.length)
        {
            read = buffer.length;
            buffer[] = m_inputBuffer[0 .. read];
            m_inputBuffer = m_inputBuffer[read .. $];
        }
        else
        {
            read = m_inputBuffer.length;
            buffer[0 .. read] = m_inputBuffer[];
            m_inputBuffer.clear();
        }
        return read;
    }

    override ptrdiff_t write(const void[] data)
    {
        foreach (i; 0 .. m_streams.length)
        {
            ptrdiff_t written = 0;
            while (written < data.length)
            {
                written += m_streams[i].write(data[written .. 0]);
            }
        }
        return 0;
    }

    override ptrdiff_t pending()
        =>m_inputBuffer.length;

    override ptrdiff_t flush()
    {
        // what this even?
        assert(0);
        foreach (stream; m_streams)
            stream.flush();
        m_inputBuffer.clear();
        return 0;
    }

    override void update()
    {
        // TODO: this is shit; polling periodically sucks, and will result in sync issues!
        //       ideally, sleeping threads blocking on a read, fill an input buffer...

        // read all streams, echo to other streams, accumulate input buffer
        foreach (i; 0 .. m_streams.length)
        {
            ubyte[1024] buf;
            size_t bytes;
            do
            {
                bytes = m_streams[i].read(buf);

//                debug
//                {
//                    if (bytes)
//                        writeDebugf("From {0}:\n{1}\n", i, cast(void[])buf[0..bytes]);
//                }

                if (bytes == 0)
                    break;

                foreach (j; 0 .. m_streams.length)
                {
                    if (j == i)
                        continue;
                    m_streams[j].write(buf[0..bytes]);
                }

                m_inputBuffer ~= buf[0..bytes];
            }
            while (bytes < buf.sizeof);
        }
    }

private:
    Array!Stream m_streams;
    Array!ubyte m_inputBuffer;
    MutableString!0 m_remoteName;
}


class BridgeStreamModule : Plugin
{
    mixin RegisterModule!"stream.bridge";

    override void init()
    {
    }

    class Instance : Plugin.Instance
    {
        mixin DeclareInstance;

        override void init()
        {
            app.console.registerCommand!add("/stream/bridge", this);
        }


        // TODO: source should be an array, and let the external code separate and validate the array args...
        void add(Session session, const(char)[] name, const(char)[][] source) nothrow @nogc
        {
            auto mod_stream = app.moduleInstance!StreamModule;

            if (name.empty)
                name = mod_stream.generateStreamName("bridge");

            // parse source streams...
            // TODO: we need move semantics for embed buffers!
//            Array!(Stream, 8) sourceStreams;
            Array!Stream sourceStreams;
            foreach (s; source)
            {
                Stream* stream = s in mod_stream.streams;
                if (stream)
                    sourceStreams ~= *stream;
            }

            String n = name.makeString(defaultAllocator());

            BridgeStream stream = app.allocator.allocT!BridgeStream(n.move, StreamOptions.NonBlocking | StreamOptions.KeepAlive, sourceStreams[]);
            mod_stream.addStream(stream);
        }
    }
}
