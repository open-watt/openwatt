module manager.stream;

import urt.conv;
import urt.mem.temp;
import urt.string;

import manager;
import manager.console;
import manager.console.command;
import manager.console.session;
import manager.config;
import manager.plugin;

import router.stream;


class StreamModule : Plugin
{
	enum string PluginName = "stream";

	this()
	{
		super(PluginName);
	}

	override Instance initInstance(ApplicationInstance instance)
	{
		return new Instance(this, instance);
	}

	class Instance : Plugin.Instance
	{
		StreamModule plugin;

		this(StreamModule plugin, ApplicationInstance instance)
		{
			super(instance);
			this.plugin = plugin;

			instance.console.registerCommand("/", new StreamCommand(instance.console, this));
		}

		override void parseConfig(ref ConfItem conf)
		{
		}
	}
}


private:

shared static this()
{
	getGlobalInstance.registerPlugin(new StreamModule);
}

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
		const(char)[][] items = tempAllocator.allocArray!(const(char)[])(appInstance.streams.keys.length);
		foreach (i, k; appInstance.streams.keys)
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
				if (tname !in appInstance.streams)
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

				appInstance.streams[name] = new TCPStream(address.idup, cast(ushort)port, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
				break;

			case "bridge":
				Stream[] bridgeStreams;
				auto streams = &appInstance.streams;
				while (!source.empty)
				{
					const(char)[] stream = source.split!','.unQuote;
					Stream* s = stream in *streams;
					if (!s)
						return session.writeLine("Stream doesn't exist: ", stream);
					bridgeStreams ~= *s;
				}
				(*streams)[name] = new BridgeStream(StreamOptions.NonBlocking | StreamOptions.KeepAlive, bridgeStreams);
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

