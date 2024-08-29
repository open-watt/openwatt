module router.stream.tcp;

import core.atomic;
import core.sync.mutex;
import core.thread;
import std.concurrency;

import urt.conv;
import urt.io;
import urt.mem;
import urt.meta.nullable;
import urt.socket;
import urt.string;
import urt.string.format;

import manager.console;
import manager.plugin;

public import router.stream;


class TCPStream : Stream
{
nothrow @nogc:

	this(String name, const(char)[] host, ushort port, StreamOptions options = StreamOptions.None)
	{
		import core.lifetime;

		super(name.move, "tcp-client", options);

		AddressInfo addrInfo;
		addrInfo.family = AddressFamily.IPv4;
		addrInfo.sockType = SocketType.Stream;
		addrInfo.protocol = Protocol.TCP;
		AddressInfoResolver results;
		get_address_info(host, port.tstring, &addrInfo, results);
		if (!results.next_address(&addrInfo))
			assert(0);
		remote = addrInfo.address;
	}

	override bool connect()
	{
		if (options & StreamOptions.ReverseConnect)
		{
//			reverseConnectServer = new TCPServer(port, (Socket client, void* userData)
//			{
//				TCPStream stream = cast(TCPStream)userData;
//
//				if (client.remoteAddress == stream.remote)
//				{
//					stream.reverseConnectServer.stop();
//					stream.reverseConnectServer = null;
//
//					client.blocking = !(stream.options & StreamOptions.NonBlocking);
//
//					stream.socket = client;
//					stream.live.atomicStore(true);
//				}
//				else
//					client.close();
//			}, cast(void*)this);
//			reverseConnectServer.start();
		}
		else
		{
			if (!create_socket(AddressFamily.IPv4, SocketType.Stream, Protocol.TCP, socket))
				assert(false, "Couldn't create socket");
			if (!socket.connect(remote))
				assert(false, "Failed to connect");

			set_socket_option(socket, SocketOption.NonBlocking, !!(options & StreamOptions.NonBlocking));
		}

		return true;
	}

	override void disconnect()
	{
//		if (reverseConnectServer !is null)
//		{
//			reverseConnectServer.stop();
//			reverseConnectServer = null;
//		}

		if (socket)
		{
//			if (socket.isAlive)
			socket.shutdown_socket(SocketShutdownMode.ReadWrite);
			socket.close_socket();
			socket = null;
		}
	}

	override bool connected()
	{
		// TODO: does this actually work?!
		ubyte[1] buffer;
		size_t bytesReceived;
		Result r = recv(socket, null, MsgFlags.Peek, &bytesReceived);
		if (r == Result.Success)
			return true;
		SocketResult sr = r.get_SocketResult;
		if (sr == SocketResult.Again || sr == SocketResult.WouldBlock)
			return true;
		return false;
	}

	override const(char)[] remoteName()
	{
		return tstring(remote);
	}

	override void setOpts(StreamOptions options)
	{
		this.options = options;
		if (socket)
		{
			set_socket_option(socket, SocketOption.NonBlocking, !!(options & StreamOptions.NonBlocking));
		}
	}

	override ptrdiff_t read(ubyte[] buffer) nothrow @nogc
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

		size_t bytes;
		Result r = socket.recv(buffer, MsgFlags.None, &bytes);
		if (r != Result.Success)
		{
			SocketResult sr = r.get_SocketResult;
			if (sr == SocketResult.WouldBlock)
				return 0;

			socket.close_socket();
			socket = null;

			// HACK: we'll need a threaded/background keep-alive strategy, but this hack might do for the moment
			if (options & StreamOptions.KeepAlive)
			{
				connect();
				return 0;
			}
			return -1;
		}
		return bytes;
	}

	override ptrdiff_t write(const ubyte[] data) nothrow @nogc
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

		size_t bytes;
		Result r = socket.send(data, MsgFlags.None, &bytes);
		if (r != Result.Success)
		{
			SocketResult sr = r.get_SocketResult;
			if (sr == SocketResult.WouldBlock)
				return 0;

			socket.close_socket();
			socket = null;

			// HACK: we'll need a threaded/background keep-alive strategy, but this hack might do for the moment
			if (options & StreamOptions.KeepAlive)
			{
				connect();
				return 0;
			}
			return -1;
		}
		return bytes;
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

		size_t bytes;
		Result r = socket.recv(null, MsgFlags.Peek, &bytes);
		if (r != Result.Success)
		{
//			SocketResult sr = r.get_SocketResult;
			socket.close_socket();
			socket = null;
		}
		return bytes;
	}

	override ptrdiff_t flush()
	{
		// TODO: read until can't read no more?
		assert(0);
	}

private:
	InetAddress remote;
	Socket socket;
//	TCPServer reverseConnectServer;

	this(String name, Socket socket, ushort port)
	{
		import core.lifetime;

		super(name.move, "serial", StreamOptions.None);
		socket.get_peer_name(remote);

		this.socket = socket;
		live.atomicStore(true);
	}
}

/+
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
	Socket serverSocket;
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
					connectionCallback(new TCPStream(StringLit!"tcp-server", clientSocket, port), userData);

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
+/

class TCPStreamModule : Plugin
{
	mixin RegisterModule!"stream.tcp";

	override void init()
	{
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
			auto mod_stream = app.moduleInstance!StreamModule;

			if (name.empty)
				mod_stream.generateStreamName("tcp-stream");

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

			String n = name.makeString(defaultAllocator);
			String a = address.makeString(defaultAllocator);

			TCPStream stream = defaultAllocator.allocT!TCPStream(n.move, a.move, cast(ushort)portNumber, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
			mod_stream.addStream(stream);
		}
	}
}
