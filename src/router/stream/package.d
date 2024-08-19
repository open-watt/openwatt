module router.stream;

import core.atomic;
import core.sync.mutex;
import core.time;

public import router.stream.bridge;
public import router.stream.serial;
public import router.stream.tcp;
public import router.stream.udp;


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
	shared static this()
	{
		mutex = new Mutex();
	}

	this(StreamOptions options)
	{
		// TODO: THIS IS YUCK!!
		addStream();

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

	// Update for all streams; monitor status, attempt reconnections, etc.
	static void update()
	{
		MonoTime now = MonoTime.currTime;

		mutex.lock();
		for (size_t i = 0; i < streams.length; )
		{
			// Opportunity for the stream to perform regular updates
			streams[i].poll();

			if (!streams[i].live.atomicLoad())
			{
				if (streams[i].options & StreamOptions.KeepAlive)
				{
					if (now - streams[i].lastConnectAttempt >= 1000.msecs)
					{
						if (streams[i].connect())
						{
							streams[i].lastConnectAttempt = MonoTime();
							streams[i].live.atomicStore(true);
						}
						else
							streams[i].lastConnectAttempt = now;
					}
				}
				else
				{
					// TODO: clean up the stream?
					//...

					streams = streams[0 .. i] ~ streams[i + 1 .. $];
				}
			}

			++i;
		}
		mutex.unlock();
	}

	// Poll the stream
	void poll()
	{
	}

package:
	__gshared Mutex mutex;
	__gshared Stream[] streams;

	shared bool live;
	StreamOptions options;
	MonoTime lastConnectAttempt;

	void addStream()
	{
		mutex.lock();
		streams ~= this;
		mutex.unlock();
	}
}
