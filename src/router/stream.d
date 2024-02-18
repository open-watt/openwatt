module router.stream;

import std.socket;
import std.stdio;

//import core.sys.posix.termios;
//import core.sys.posix.unistd;

enum StreamOptions
{
	None = 0,
	NonBlocking = 1 << 0, // Non-blocking IO
	ReverseConnect = 1 << 1, // For TCP connections where remote will initiate connection
	KeepAlive = 1 << 2, // Attempt reconnection on connection drops
	BufferData = 1 << 3, // Buffer read/write data when stream is not ready
}

abstract class Stream
{
	shared static this()
	{
		mutex = new Mutex();
	}

	this(StreamOptions options)
	{
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

package:
	import core.atomic;

	__gshared Mutex mutex;
	__gshared Stream[] streams;

	shared bool live;
	StreamOptions options;
	MonoTime lastConnectAttempt;

	// Poll the stream
	void poll()
	{
	}

	void addStream()
	{
		mutex.lock();
		streams ~= this;
		mutex.unlock();
	}
}

class TCPStream : Stream
{
	this(string host, ushort port, StreamOptions options = StreamOptions.None)
	{
		super(options);
		this.host = host;
		this.port = port;

		Address[] addrs = getAddress(host, port);
		if (addrs.length == 0)
		{
			assert(0);
		}
		else if (addrs.length > 1)
		{
			writeln("TODO: what do to with additional addresses?");
		}
		remote = addrs[0];
	}

	override bool connect()
	{
		if (options & StreamOptions.ReverseConnect)
		{
			reverseConnectServer = new TCPServer(port, (Socket client, void* userData)
			{
				TCPStream stream = cast(TCPStream)userData;

				if (client.remoteAddress == stream.remote)
				{
					stream.reverseConnectServer.stop();
					stream.reverseConnectServer = null;

					client.blocking = !(stream.options & StreamOptions.NonBlocking);

					stream.socket = client;
					stream.live.atomicStore(true);
				}
				else
					client.close();
			}, cast(void*)this);
			reverseConnectServer.start();
		}
		else
		{
			socket = new TcpSocket();
			socket.connect(remote);

			if (!socket.isAlive)
			{
				socket.close();
				socket = null;
				return false;
			}

			socket.blocking = !(options & StreamOptions.NonBlocking);
		}

		return true;
	}

	override void disconnect()
	{
		if (reverseConnectServer !is null)
		{
			reverseConnectServer.stop();
			reverseConnectServer = null;
		}

		if (socket !is null)
		{
//			if (socket.isAlive)
				socket.shutdown(SocketShutdown.BOTH);
			socket.close();
			socket = null;
		}
	}

	override bool connected()
	{
		return !(socket is null || !socket.isAlive);
	}

	override string remoteName()
	{
		return host;
	}

	override void setOpts(StreamOptions options)
	{
		this.options = options;
		if (socket)
			socket.blocking = !(options & StreamOptions.NonBlocking);
	}

	override ptrdiff_t read(ubyte[] buffer)
	{
		if (!connected())
		{
			if (options & StreamOptions.KeepAlive)
			{
				connect();
				if (!connected())
					return 0;
			}
			else
				return -1;
		}

		long r = socket.receive(buffer);
		if (r == Socket.ERROR)
		{
			if (wouldHaveBlocked())
				return 0;

			socket.close();
			socket = null;

			// HACK: we'll need a threaded/background keep-alive strategy, but this hack might do for the moment
			if (options & StreamOptions.KeepAlive)
			{
				connect();
				return 0;
			}
			return -1;
		}
		return cast(size_t) r;
	}

	override ptrdiff_t write(const ubyte[] data)
	{
		if (!connected())
		{
			if (options & StreamOptions.KeepAlive)
			{
				connect();
				if (!connected())
					return 0;
			}
			else
				return -1;
		}

		long r = socket.send(data);
		if (r == Socket.ERROR)
		{
			if (wouldHaveBlocked())
				return 0;

			socket.close();
			socket = null;

			// HACK: we'll need a threaded/background keep-alive strategy, but this hack might do for the moment
			if (options & StreamOptions.KeepAlive)
			{
				connect();
				return 0;
			}
			return -1;
		}
		return cast(size_t) r;
	}

	override ptrdiff_t pending()
	{
		if (!connected())
		{
			if (options & StreamOptions.KeepAlive)
			{
				connect();
				return 0;
			}
			else
				return -1;
		}

		long r = socket.receive(null, SocketFlags.PEEK);
		if (r == 0 || r == Socket.ERROR)
		{
			socket.close();
			socket = null;
		}
		return cast(size_t) r;
	}

	override ptrdiff_t flush()
	{
		// TODO: read until can't read no more?
		assert(0);
	}

private:
	string host;
	ushort port;
	Address remote;
	Socket socket;
	TCPServer reverseConnectServer;

	this(Socket socket, ushort port)
	{
		super(StreamOptions.None);
		this.port = port;
		remote = socket.remoteAddress;
		host = remote.toString;

		this.socket = socket;
		live.atomicStore(true);
	}
}

class UDPStream : Stream
{
	this(string host, ushort port, StreamOptions options = StreamOptions.None)
	{
		super(options);
		this.host = host;
		this.port = port;

		Address[] addrs = getAddress(host, port);
		if (addrs.length == 0)
		{
			assert(0);
		}
		else if (addrs.length > 1)
		{
			writeln("TODO: what do to with additional addresses?");
		}
		remote = addrs[0];
	}

	override bool connect()
	{
		socket = new UdpSocket();
		socket.bind(new InternetAddress("0.0.0.0", port));
		return true;
	}

	override void disconnect()
	{
		if (socket !is null)
		{
			socket.shutdown(SocketShutdown.BOTH);
			socket.close();
			socket = null;
		}
	}

	override ptrdiff_t read(ubyte[] buffer)
	{
		long r = socket.receiveFrom(buffer, remote);
		if (r == Socket.ERROR)
		{
			// TODO?
			assert(0);
		}
		return cast(size_t) r;
	}

	override ptrdiff_t write(const ubyte[] data)
	{
		long r = socket.sendTo(data, remote);
		if (r == Socket.ERROR)
		{
			// TODO?
			assert(0);
		}
		return cast(size_t) r;
	}

private:
	UdpSocket socket;
	string host;
	ushort port;
	Address remote;
}


import core.atomic;
import core.sync.mutex;
import core.thread;
import std.socket;
import std.concurrency;
import std.stdio;

enum ServerOptions
{
	None = 0,
	JustOne = 1 << 0, // Only accept one connection then terminate the server
}

class TCPServer
{
	alias NewConnection = void function(TCPStream client, void* userData);

	this(ushort port, NewConnection callback, void* userData, ServerOptions options = ServerOptions.None)
	{
		this.port = port;
		this.options = options;
		this.connectionCallback = callback;
		this.userData = userData;
		mutex = new Mutex;
	}

	void start()
	{
		serverSocket = new TcpSocket();
		serverSocket.bind(new InternetAddress(port));
		serverSocket.listen(10); // Listen with a queue of 10 connections
		isRunning.atomicStore(true);
		writeln("TCP server listening on port ", port);
		listenThread = new Thread(&acceptConnections).start();
	}

	void stop()
	{
		isRunning.atomicStore(false);
		mutex.lock();
		if (serverSocket)
		{
			serverSocket.close();
			serverSocket = null;
		}
		mutex.unlock();
	}

	bool running()
	{
		return isRunning.atomicLoad();
	}

private:
	alias NewRawConnection = void function(Socket client, void* userData);

	ServerOptions options;
	immutable ushort port;
	shared bool isRunning;
	NewConnection connectionCallback;
	NewRawConnection rawConnectionCallback;
	void* userData;
	TcpSocket serverSocket;
	Thread listenThread;
	Mutex mutex;

	this(ushort port, NewRawConnection callback, void* userData, ServerOptions options = ServerOptions.None)
	{
		this.port = port;
		this.options = options;
		this.rawConnectionCallback = callback;
		this.userData = userData;
		mutex = new Mutex;
	}

	void acceptConnections()
	{
		mutex.lock();
		TcpSocket server = serverSocket;
		mutex.unlock();
		if (!server)
			return;
		while (isRunning.atomicLoad())
		{
			try
			{
				auto clientSocket = server.accept();
				writeln("Accepted TCP connection from ", clientSocket.remoteAddress.toString());

				if (rawConnectionCallback)
					rawConnectionCallback(clientSocket, userData);
				else if (connectionCallback)
					connectionCallback(new TCPStream(clientSocket, port), userData);

				if (options & ServerOptions.JustOne)
				{
					stop();
					break;
				}
			}
			catch (Exception e)
			{
				// I think this means the socket was destroyed?
			}
		}
	}
}
