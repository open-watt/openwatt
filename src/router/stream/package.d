module router.stream;

import core.lifetime;

import urt.conv;
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
	NonBlocking = 1 << 0, // Non-blocking IO
	ReverseConnect = 1 << 1, // For TCP connections where remote will initiate connection
	KeepAlive = 1 << 2, // Attempt reconnection on connection drops
	BufferData = 1 << 3, // Buffer read/write data when stream is not ready
	AllowBroadcast = 1 << 4, // Allow broadcast messages
}

abstract class Stream
{
	CacheString type;

	this(const(char)[] type, StreamOptions options)
	{
		this.type = addString(type);
		this.options = options;
	}

	// Method to initiate a connection
	abstract bool connect();

	// Method to disconnect the stream
	abstract void disconnect();

	// Check if the stream is connected
	abstract bool connected() nothrow @nogc;

	abstract string remoteName();

	abstract void setOpts(StreamOptions options);

	// Read data from the stream
	abstract ptrdiff_t read(ubyte[] buffer) nothrow @nogc;

	// Write data to the stream
	abstract ptrdiff_t write(const ubyte[] data) nothrow @nogc;

	// Return the number of bytes in the read buffer
	abstract ptrdiff_t pending();

	// Flush the receive buffer (return number of bytes destroyed)
	abstract ptrdiff_t flush();

	// Poll the stream
	void poll()
	{
	}

package:
	bool live;
	StreamOptions options;
	MonoTime lastConnectAttempt;
}

class StreamTypeInfo
{
	String name;

	this(String name)
	{
		this.name = name.move;
	}

	abstract Stream create(KVP[] params);

	// TODO: parse command line stuff...
}

class StreamModule : Plugin
{
	mixin RegisterModule!"stream";

	StreamTypeInfo[] streamTypes;

	void registerStreamType(StreamTypeInfo streamTypeInfo)
	{
		assert(!getStreamType(streamTypeInfo.name), "Stream type already registered");
		streamTypes ~= streamTypeInfo;
	}

	StreamTypeInfo getStreamType(const(char)[] type)
	{
		foreach (s; streamTypes)
		{
			if (s.name == type)
				return s;
		}
		return null;
	}

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		Stream[string] streams;

		override void init()
		{
			app.console.registerCommand!add("/stream", this);
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

			MonoTime now = getTime();

			foreach (stream; streams)
			{
				// Opportunity for the stream to perform regular updates
				stream.poll();

				if (!stream.live)
				{
					if (stream.options & StreamOptions.KeepAlive)
					{
						if (now - stream.lastConnectAttempt >= 1000.msecs)
						{
							if (stream.connect())
							{
								stream.lastConnectAttempt = MonoTime();
								stream.live = true;
							}
							else
								stream.lastConnectAttempt = now;
						}
					}
					else
					{
						// TODO: clean up the stream?
						//...
						assert(false);
					}
				}
			}
		}

		void add(Session session, const(char)[] name, const(char)[] type, const(char)[] address, const(char)[] source, Nullable!int port)
		{
			if (name.empty)
			{
				foreach (i; 0 .. ushort.max)
				{
					const(char)[] tname = i == 0 ? type : tconcat(type, i);
					if (tname !in streams)
					{
						name = tname.idup;
						break;
					}
				}
			}

			switch (type)
			{
				case "tcp-client":
					const(char)[] portSuffix = address;
					address = portSuffix.split!':';
					uint portNumber = 0;

					if (port)
					{
						if (portSuffix)
							return session.writeLine("Port specified twice");
						portNumber = port.value;
					}

					size_t taken;
					if (!port)
					{
						portNumber = cast(uint)portSuffix.parseInt(&taken);
						if (taken == 0)
							return session.writeLine("Port must be numeric: ", portSuffix);
					}
					if (portNumber - 1 > ushort.max - 1)
						return session.writeLine("Invalid port number (1-65535): ", portNumber);

//					instance.streams[name] = new TCPStream(address.idup, cast(ushort)port, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
					break;

				case "bridge":
					Stream[] bridgeStreams;
					while (!source.empty)
					{
						const(char)[] stream = source.split!','.unQuote;
						Stream* s = stream in streams;
						if (!s)
							return session.writeLine("Stream doesn't exist: ", stream);
						bridgeStreams ~= *s;
					}
//					(*streams)[name] = new BridgeStream(StreamOptions.NonBlocking | StreamOptions.KeepAlive, bridgeStreams);
					break;

				default:
					session.writeLine("Invalid stream type: ", type);
					return;
			}
		}
	}
}


private:
