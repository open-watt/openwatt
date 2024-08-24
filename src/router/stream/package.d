module router.stream;

import core.lifetime;

import urt.conv;
import urt.mem.string;
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
	abstract bool connected();

	abstract string remoteName();

	abstract void setOpts(StreamOptions options);

	// Read data from the stream
	abstract ptrdiff_t read(ubyte[] buffer);

	// Write data to the stream
	abstract ptrdiff_t write(const ubyte[] data);

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
			app.console.registerCommand("/", new StreamCommand(app.console, this));
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
	}
}


private:

class StreamCommand : Collection
{
	import manager.console.expression;

	StreamModule.Instance instance;

	this(ref Console console, StreamModule.Instance instance)
	{
		import urt.mem.string;

		super(console, StringLit!"stream", cast(Collection.Features)(Collection.Features.AddRemove | Collection.Features.SetUnset | Collection.Features.EnableDisable | Collection.Features.Print | Collection.Features.Comment));
		this.instance = instance;
	}

	override const(char)[][] getItems()
	{
		import urt.mem.allocator;
		const(char)[][] items = tempAllocator.allocArray!(const(char)[])(instance.streams.keys.length);
		foreach (i, k; instance.streams.keys)
			items[i] = k;
		return items;
	}

	override void add(KVP[] params)
	{
		string name;
		const(char)[] type;
		const(char)[] address;
		const(char)[] source;
		Token* portToken;

		foreach (ref p; params)
		{
			if (p.k.type != Token.Type.Identifier)
				goto bad_parameter;
			switch (p.k.token[])
			{
				case "name":
					if (p.v.type == Token.Type.String)
						name = p.v.token[].unQuote.idup;
					else
						name = p.v.token[].idup;
					break;
				case "type":
					type = p.v.token[];
					break;
				case "address":
					address = p.v.token[];
					break;
				case "source":
					source = p.v.token[];
					break;
				case "port":
					portToken = &p.v;
					break;
				default:
				bad_parameter:
					session.writeLine("Invalid parameter name: ", p.k.token);
					return;
			}
		}

		if (name.empty)
		{
			foreach (i; 0 .. ushort.max)
			{
				const(char)[] tname = i == 0 ? type : tconcat(type, i);
				if (tname !in instance.streams)
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
				size_t port = 0;

				if (portToken)
				{
					if (portSuffix)
						return session.writeLine("Port specified twice");
					portSuffix = portToken.token;
				}

				size_t taken;
				if (!portToken || portToken.type == Token.Type.Number)
					port = portSuffix.parseInt(&taken);
				if (taken == 0)
					return session.writeLine("Port must be numeric: ", portSuffix);
				if (port - 1 > ushort.max - 1)
					return session.writeLine("Invalid port number (1-65535): ", port);

//				instance.streams[name] = new TCPStream(address.idup, cast(ushort)port, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
				break;

			case "bridge":
				Stream[] bridgeStreams;
				auto streams = &instance.streams;
				while (!source.empty)
				{
					const(char)[] stream = source.split!','.unQuote;
					Stream* s = stream in *streams;
					if (!s)
						return session.writeLine("Stream doesn't exist: ", stream);
					bridgeStreams ~= *s;
				}
//				(*streams)[name] = new BridgeStream(StreamOptions.NonBlocking | StreamOptions.KeepAlive, bridgeStreams);
				break;

			default:
				session.writeLine("Invalid stream type: ", type);
				return;
		}
	}

	override void remove(const(char)[] item)
	{
		int x = 0;
	}

	override void set(const(char)[] item, KVP[] params)
	{
		int x = 0;
	}

	override void print(KVP[] params)
	{
		int x = 0;
	}
}

