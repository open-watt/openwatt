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
}

abstract class Stream
{
	// Method to initiate a connection
	abstract bool connect();

	// Method to disconnect the stream
	abstract void disconnect();

	// Check if the stream is connected
	abstract bool connected();

	// Method to reconnect the stream in case the connection is lost
	void reconnect()
	{
		if (connected())
			disconnect();
		connect();
	}

	// Read data from the stream
	abstract ptrdiff_t read(ubyte[] buffer);

	// Write data to the stream
	abstract ptrdiff_t write(const ubyte[] data);

	// Return the number of bytes in the read buffer
	abstract ptrdiff_t pending();

	// Flush the receive buffer (return number of bytes destroyed)
	abstract ptrdiff_t flush();
}

class TCPStream : Stream
{
	this(string host, ushort port, StreamOptions options = StreamOptions.None)
	{
		this.host = host;
		this.port = port;
		this.options = options;

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
			// create listening socket and wait for incoming connection from the expected client
			assert(0);
		}

		socket = new TcpSocket();
		socket.connect(remote);

		if (!socket.isAlive)
		{
			socket.close();
			socket = null;
			return false;
		}

		socket.blocking = !(options & StreamOptions.NonBlocking);

		return true;
	}

	override void disconnect()
	{
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
	Socket socket;
	string host;
	ushort port;
	StreamOptions options;
	Address remote;
}

class UDPStream : Stream
{
	this(string host, ushort port, StreamOptions options = StreamOptions.None)
	{
		this.host = host;
		this.port = port;
		this.options = options;

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
	StreamOptions options;
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

class Server
{
	this(ushort port, ServerOptions options = ServerOptions.None)
	{
		this.port = port;
		this.options = options;
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
		serverSocket.close();

		mutex.lock();
		serverSocket = null;
		mutex.unlock();
	}

	bool running()
	{
		return isRunning.atomicLoad();
	}

	Socket getNewConnection()
	{
		mutex.lock();
		if (newClients.length == 0)
			return null;
		Socket conn = newClients[0];
		newClients = newClients[1 .. $];
		mutex.unlock();
		return conn;
	}

private:
	ushort port;
	ServerOptions options;
	Mutex mutex;
	shared bool isRunning;
	TcpSocket serverSocket;
	Socket[] newClients;
	Thread listenThread;

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

				mutex.lock();
				newClients ~= clientSocket;
				mutex.unlock();

				if (options & ServerOptions.JustOne)
				{
					isRunning.atomicStore(false);
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
