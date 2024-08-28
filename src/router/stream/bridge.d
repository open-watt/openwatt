module router.stream.bridge;

import urt.log;
import urt.mem;
import urt.string;
import urt.string.format;

import manager.console;
import manager.plugin;

public import router.stream;

class BridgeStream : Stream
{
	this(String name, StreamOptions options, Stream[] streams...) nothrow @nogc
	{
		import core.lifetime;

		super(name.move, "bridge", options);

		this.streams = streams;
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

	override string remoteName()
	{
		string name = "bridge[";
		for (size_t i = 0; i < streams.length; ++i)
		{
			if (i > 0)
				name ~= "|";
			name ~= streams[i].remoteName();
		}
		name ~= "]";
		return name;
	}

	override void setOpts(StreamOptions options)
	{
		this.options = options;
	}

	override ptrdiff_t read(ubyte[] buffer)
	{
		size_t read;
		if (buffer.length < inputBuffer.length)
		{
			read = buffer.length;
			buffer[] = inputBuffer[0 .. read];
			inputBuffer = inputBuffer[read .. $];
		}
		else
		{
			read = inputBuffer.length;
			buffer[0 .. read] = inputBuffer[];
			inputBuffer.length = 0;
		}
		return read;
	}

	override ptrdiff_t write(const ubyte[] data)
	{
		foreach (i; 0 .. streams.length)
		{
			ptrdiff_t written = 0;
			while (written < data.length)
			{
				written += streams[i].write(data[written .. 0]);
			}
		}
		return 0;
	}

	override ptrdiff_t pending()
	{
		return inputBuffer.length;
	}

	override ptrdiff_t flush()
	{
		// what this even?
		assert(0);
		foreach (stream; streams)
			stream.flush();
		inputBuffer.length = 0;
		return 0;
	}

	override void poll()
	{
		// TODO: this is shit; polling periodically sucks, and will result in sync issues!
		//       ideally, sleeping threads blocking on a read, fill an input buffer...

		// read all streams, echo to other streams, accumulate input buffer
		foreach (i; 0 .. streams.length)
		{
			ubyte[1024] buf;
			size_t bytes;
			do
			{
				bytes = streams[i].read(buf);

//				debug
//				{
//					if (bytes)
//						writeDebugf("From {0}:\n{1}\n", i, cast(void[])buf[0..bytes]);
//				}

				if (bytes == 0)
					break;

				foreach (j; 0 .. streams.length)
				{
					if (j == i)
						continue;
					streams[j].write(buf[0..bytes]);
				}

				inputBuffer ~= buf[0..bytes];
			}
			while (bytes < buf.sizeof);
		}
	}

private:
	Stream[] streams;

	ubyte[] inputBuffer;
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
		void add(Session session, const(char)[] name, const(char)[][] source)
		{
			auto mod_stream = app.moduleInstance!StreamModule;

			if (name.empty)
				name = mod_stream.generateStreamName("bridge");

			// parse source streams...
			Stream[] sourceStreams;
			foreach (s; source)
			{
				Stream* stream = s in mod_stream.streams;
				if (stream)
					sourceStreams ~= *stream;
			}

			String n = name.makeString(defaultAllocator());

			BridgeStream stream = defaultAllocator.allocT!BridgeStream(n.move, StreamOptions.NonBlocking | StreamOptions.KeepAlive, sourceStreams);
			mod_stream.addStream(stream);
		}
	}
}
