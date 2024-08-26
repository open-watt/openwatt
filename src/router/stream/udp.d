module router.stream.udp;

import std.socket;
import std.stdio;

import urt.string.format;

import manager.plugin;

public import router.stream;


class UDPStream : Stream
{
	this(ushort remotePort, string remoteHost = "255.255.255.255", ushort localPort = 0, string localHost = "0.0.0.0", StreamOptions options = StreamOptions.None)
	{
		// TODO: if remoteHost is a broadcast address and options doesn't have `AllowBroadcast`, make a warning...

		super("udp", options);
		this.localHost = localHost;
		this.localPort = localPort;
		this.remoteHost = remoteHost;
		this.remotePort = remotePort;

		Address[] addrs = getAddress(localHost, localPort);
		if (addrs.length == 0)
		{
			assert(0);
		}
		else if (addrs.length > 1)
		{
			writeln("TODO: what do to with additional addresses?");
		}
		local = addrs[0];
		addrs = getAddress(remoteHost, remotePort);
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
		socket.bind(local);
		socket.blocking = !(options & StreamOptions.NonBlocking);
		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.BROADCAST, (options & StreamOptions.AllowBroadcast) ? 1 : 0);
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

	override bool connected() nothrow @nogc
	{
		return true;
	}

	override string remoteName()
	{
		return remoteHost;
	}

	override void setOpts(StreamOptions options)
	{
		this.options = options;
		if (socket)
			socket.blocking = !(options & StreamOptions.NonBlocking);
		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.BROADCAST, (options & StreamOptions.AllowBroadcast) ? 1 : 0);
	}

	override ptrdiff_t read(ubyte[] buffer) nothrow @nogc
	{
		// HACK!!!
		try {
			auto d = &read_impl;
			return (cast(ptrdiff_t delegate(ubyte[]) nothrow @nogc)d)(buffer);
		}
		catch (Exception)
			return -1;
	}

	final ptrdiff_t read_impl(ubyte[] buffer)
	{
		Address from;
		long r = socket.receiveFrom(buffer, from);
		if (r == Socket.ERROR)
		{
			if (wouldHaveBlocked())
				return 0;

			// TODO?
			assert(0);
		}
		// if remote is not a broadcast addr, we need to confirm we received from our designated remote
		// TODO: ...
		return cast(ptrdiff_t)r;
	}

	override ptrdiff_t write(const ubyte[] data) nothrow @nogc
	{
		// HACK!!!
		try {
			auto d = &write_impl;
			return (cast(ptrdiff_t delegate(const ubyte[]) nothrow @nogc)d)(data);
		}
		catch (Exception)
			return -1;
	}

	final ptrdiff_t write_impl(const ubyte[] data)
	{
		long r = socket.sendTo(data, remote);
		if (r == Socket.ERROR)
		{
			// TODO?
			assert(0);
		}
		return cast(ptrdiff_t)r;
	}

	ptrdiff_t recvfrom(ubyte[] msgBuffer, out char[] srcAddr, char[] addrBuffer = null)
	{
		Address from;
		long r = socket.receiveFrom(msgBuffer, from);
		if (r == Socket.ERROR)
		{
			// TODO?
			assert(0);
		}
		// TODO: stringify `from`
		//...
		return cast(ptrdiff_t)r;
	}

	ptrdiff_t sendto(const ubyte[] data, const(char)[] destAddr)
	{
		// TODO: we shouldn't use getAddress here, string should be ip address only, no hostnames here...
		Address[] addrs = getAddress(destAddr);
		if (addrs.length == 0)
			assert(0);
		else if (addrs.length > 1)
			writeln("TODO: what do to with additional addresses?");

		long r = socket.sendTo(data, addrs[0]);
		if (r == Socket.ERROR)
		{
			// TODO?
			assert(0);
		}
		return cast(ptrdiff_t)r;
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
	UdpSocket socket;
	string localHost;
	string remoteHost;
	ushort localPort;
	ushort remotePort;
	Address local;
	Address remote;
}


class UDPStreamModule : Plugin
{
	mixin RegisterModule!"stream.udp";

	override void init()
	{
	}

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;
	}
}
