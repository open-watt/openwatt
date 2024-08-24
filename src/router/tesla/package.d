module router.tesla;

import std.conv;
import std.stdio;
import std.uni : toLower;

import manager;
import manager.config;
import manager.component;
import manager.device;
import manager.element;
import manager.plugin;
import manager.units;
import manager.value;

import router.stream.tcp;
import router.tesla.twc;

import urt.log;
import urt.mem.string;
import urt.string;


class TeslaPlugin : Plugin
{
	mixin RegisterModule!"tesla";

	override void init()
	{
	}

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		TeslaWallConnector[string] twcs;

		override void init()
		{
			// register modbus component
			app.registerComponentType("twc-component", &createTWCComponent);
		}

		override void preUpdate()
		{
			// TODO: polling is pretty lame! data connections should be in threads and receive data immediately
			// processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)
			foreach (twc; twcs)
				twc.poll();
		}

		override void parseConfig(ref ConfItem conf)
		{
			import router.stream;

			foreach (ref dev; conf.subItems) switch (dev.name)
			{
				case "twc":
					string id;
					Stream stream;

					foreach (ref param; dev.subItems) switch (param.name)
					{
						case "id":
							id = param.value.unQuote.idup;
							break;

						case "stream":
							const(char)[] streamName = param.value.unQuote;
							stream = app.moduleInstance!StreamModule.getStream(streamName);
							if (!stream)
								writeln("Invalid stream: ", streamName);
							break;

						case "tcp-server":
							break;

						case "tcp-client":
							string addr, port, options = param.value;
							port = options.split!',';
							addr = port.split!':'.unQuote.idup;
							ushort p = port.to!ushort;
							stream = new TCPStream(addr, p ? p : 502, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
							break;

						case "udp-server":
							break;

						case "udp-client":
							break;

						case "serial":
							break;

						default:
							writeln("Invalid token: ", param.name);
					}

					twcs[id] = new TeslaWallConnector(id, stream);
/+
					app.servers[id] = twcs[id];
+/
					break;

				default:
					writeln("Invalid token: ", dev.name);
			}
		}

		Component* createTWCComponent(Device* device, ref ConfItem config)
		{
			string id, name, server;
			foreach (ref com; config.subItems) switch (com.name)
			{
				case "id":
					id = com.value.unQuote.idup;
					break;
				case "name":
					name = com.value.unQuote.idup;
					break;
				case "server":
					server = com.value.unQuote.idup;
					break;
				default:
					writeln("Invalid token: ", com.name);
			}
/+
			Server* pServer = server in app.servers;
			// TODO: proper error message
			assert(pServer, "No server");

			TeslaWallConnector twcServer = pServer ? cast(TeslaWallConnector)*pServer : null;
			// TODO: proper error message
			assert(twcServer, "Not a TWC server");

			Component* component = new Component;
			component.id = addString(id);
			component.name = addString(name);

			return component;
+/
			return null;
		}
	}
}


private:
