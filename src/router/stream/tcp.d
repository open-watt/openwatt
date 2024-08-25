module router.stream.tcp;

import core.atomic;
import core.sync.mutex;
import core.thread;
import std.socket;
import std.concurrency;
import std.stdio;

import urt.conv;
import urt.meta.nullable;
import urt.string;
import urt.string.format;

import manager.console;
import manager.plugin;

public import router.stream;


class TCPStream : Stream
{
	this(string host, ushort port, StreamOptions options = StreamOptions.None)
	{
		super("tcp-client", options);
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
		super("serial", StreamOptions.None);
		this.port = port;
		remote = socket.remoteAddress;
		host = remote.toString;

		this.socket = socket;
		live.atomicStore(true);
	}
}

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

class TCPStreamTypeInfo : StreamTypeInfo
{
	this()
	{
		super(StringLit!"tcp-client");
	}

	override TCPStream create(KVP[] params)
	{
//		return new TCPStream();
		return null;
	}
}

class TCPStreamModule : Plugin
{
	mixin RegisterModule!"stream.tcp";

	override void init()
	{
//		global.getModule!StreamModule.registerStreamType(new TCPStreamTypeInfo);
	}

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		override void init()
		{
			app.console.registerCommand!add("/stream/tcp-client", this);
		}

		void add(Session session, const(char)[] name, const(char)[] address, Nullable!int port)
		{
			auto streams = &app.moduleInstance!StreamModule.streams;

			if (name.empty)
			{
				foreach (i; 0 .. ushort.max)
				{
					const(char)[] tname = i == 0 ? "tcp-stream" : tconcat("tcp-stream", i);
					if (tname !in *streams)
					{
						name = tname.idup;
						break;
					}
				}
			}

			const(char)[] portSuffix = address;
			address = portSuffix.split!':';
			size_t portNumber = 0;

			if (port)
			{
				if (portSuffix)
					return session.writeLine("Port specified twice");
				portNumber = port.value;
			}

			size_t taken;
			if (!port)
			{
				portNumber = portSuffix.parseInt(&taken);
				if (taken == 0)
					return session.writeLine("Port must be numeric: ", portSuffix);
			}
			if (portNumber - 1 > ushort.max - 1)
				return session.writeLine("Invalid port number (1-65535): ", portNumber);

			(*streams)[name] = new TCPStream(address.idup, cast(ushort)portNumber, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
		}
	}
}
