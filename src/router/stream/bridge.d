module router.stream.bridge;

import urt.array;
import urt.log;
import urt.mem;
import urt.string;
import urt.string.format;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

public import router.stream;

nothrow @nogc:


class BridgeStream : Stream
{
    __gshared Property[1] Properties = [ Property.create!("streams", streams)() ];
nothrow @nogc:

    alias TypeName = StringLit!"bridge-stream";

    this(String name, ObjectFlags flags = ObjectFlags.None, StreamOptions options = StreamOptions.None)
    {
        super(collectionTypeInfo!BridgeStream, name.move, flags, options);
    }

    // Properties

    ref const(Array!(ObjectRef!Stream)) streams() const
        => m_streams;
    void streams(Stream[] value...)
    {
        m_streams.clear();
        m_streams.reserve(value.length);
        foreach (s; value)
            m_streams.emplaceBack(s);

        m_remoteName.reserve(60);
        m_remoteName = TypeName[]; // reset remote name
        m_remoteName ~= '[';
        foreach (i, s; value)
        {
            if (i > 0)
                m_remoteName ~= '|';
            m_remoteName ~= s.remoteName();
        }
        m_remoteName ~= ']';
    }

    override void update()
    {
        // TODO: this is shit; polling periodically sucks, and will result in sync issues!
        //       ideally, sleeping threads blocking on a read, fill an input buffer...

        // read all streams, echo to other streams, accumulate input buffer
        foreach (i; 0 .. m_streams.length)
        {
            if (!m_streams[i] || !m_streams[i].running)
                continue;

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

    override const(char)[] remoteName()
        => m_remoteName;

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
        if (logging)
            writeToLog(true, buffer[0 .. read]);
        return read;
    }

    override ptrdiff_t write(const void[] data)
    {
        foreach (i; 0 .. m_streams.length)
        {
            ptrdiff_t written = 0;
            while (written < data.length)
            {
                if (m_streams[i] && m_streams[i].running)
                    written += m_streams[i].write(data[written .. $]);
            }
        }
        if (logging)
            writeToLog(false, data);
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

private:
    Array!(ObjectRef!Stream) m_streams;
    Array!ubyte m_inputBuffer;
    MutableString!0 m_remoteName;
}


class BridgeStreamModule : Module
{
    mixin DeclareModule!"stream.bridge";
nothrow @nogc:

    Collection!BridgeStream bridges;

    override void init()
    {
        g_app.console.registerCollection("/stream/bridge", bridges);
    }
}
