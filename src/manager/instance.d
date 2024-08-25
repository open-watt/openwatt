module manager.instance;

import std.conv : to;
import std.uni : toLower;

import manager;
import manager.console;
import manager.component;
import manager.config;
import manager.device;
import manager.element;
import manager.plugin;
import manager.units;

//import router.modbus.connection;
//import router.modbus.profile;
//import router.mqtt.broker;
//import router.server;

import urt.log;
import urt.io;
import urt.mem.string;
import urt.mem.temp;
import urt.string;


alias CreateComponentFunc = Component* delegate(Device* device, ref ConfItem config);

class ApplicationInstance
{
	string name;
	GlobalInstance global;
	Plugin.Instance[] pluginInstance;

	CreateComponentFunc[string] customComponents;

	Console console;

	Device*[String] devices;

	// database...

	this()
	{
		import urt.mem;

		console = Console(this, String("console".addString), Mallocator.instance);
	}

	Plugin.Instance moduleInstance(string name)
	{
		foreach (i; 0 .. global.modules.length)
			if (global.modules[i].moduleName[] == name[])
				return pluginInstance[i];
		return null;
	}

	I.Instance moduleInstance(I)()
	{
		return cast(I.Instance)moduleInstance(I.ModuleName);
	}

	void registerComponentType(string type, CreateComponentFunc createFunc)
	{
		customComponents[type] = createFunc;
	}

	void update()
	{
		foreach (plugin; pluginInstance)
			plugin.preUpdate();

		foreach (plugin; pluginInstance)
			plugin.update();

		// TODO: polling is pretty lame! data connections should be in threads and receive data immediately
		// processing should happen in a processing thread which waits on a semaphore for jobs in a queue (submit from comms threads?)
//		foreach (server; servers)
//			server.poll();
		foreach (device; devices)
			device.update();

		foreach (plugin; pluginInstance)
			plugin.postUpdate();
	}

	void loadConfig(string filename)
	{
		ConfItem confRoot = parseConfigFile(filename);

		foreach (ref confItem; confRoot.subItems) switch (confItem.name)
		{
			case "global":
				foreach (ref opt; confItem.subItems) switch (opt.name)
				{
					case "loglevel":
						foreach (i, level; levelNames)
						{
							if (opt.value.unQuote.toLower[] == level.toLower[])
								logLevel = cast(Level)i;
						}
						break;

					default:
						writeln("Invalid token: ", opt.name);
				}
				break;
/+
			case "connections":
				foreach (ref conn; confItem.subItems)
				{
					switch (conn.name)
					{
						case "tcp-client":
							string name, addr, port, options, tail = conn.value;
							name = tail.split!','.unQuote;
							port = tail.split!',';
							addr = port.split!':'.unQuote;
							options = tail.split!',';
							// TODO: if !tail.empty, warn about unexpected data...
							streams[name] = new TCPStream(addr, port.to!ushort, StreamOptions.NonBlocking | StreamOptions.KeepAlive);
							break;

						case "bridge":
							Stream[] bridgeStreams;
							string name, tail = conn.value;
							name = tail.split!','.unQuote;
							while (!tail.empty)
							{
								string stream = tail.split!','.unQuote;
								Stream* s = stream in streams;
								if (s)
									bridgeStreams ~= *s;
								else
									writeln("Stream not found: ", stream);
							}
							streams[name] = new BridgeStream(StreamOptions.NonBlocking | StreamOptions.KeepAlive, bridgeStreams);
							break;

						default:
							writeln("Invalid token: ", conn.name);
					}
				}
				break;
+/
			case "device":
				Device* device = new Device;

				foreach (ref devConf; confItem.subItems) switch (devConf.name)
				{
					case "id":
						device.id = addString(devConf.value.unQuote);
						break;

					case "name":
						device.name = addString(devConf.value.unQuote);
						break;

					case "component":
						break;

					default:
						if (devConf.name in customComponents)
						{
							CreateComponentFunc createFunc = customComponents[devConf.name];
							Component* component = createFunc(device, devConf);
							assert(component); // TODO: runtime error...
							device.addComponent(component);
						}
						else
						{
							writeln("Invalid token: ", devConf.name);
						}
						break;
				}

				device.finalise();

				// TODO: proper error message
				assert(device.id);
				devices[device.id] = device;
				break;
/+
			case "mqtt":
				foreach (ref mqtt; confItem.subItems) switch (mqtt.name)
				{
					case "broker":
						MQTTBrokerOptions options;

						foreach (ref opt; mqtt.subItems) switch (opt.name)
						{
							case "port":
								options.port = opt.value.to!ushort;
								break;

							case "flags":
								while (!opt.value.empty)
								{
									string flag = opt.value.split!'|'.toLower;
									switch (flag)
									{
										case "allowanonymous":
											options.flags |= MQTTBrokerOptions.Flags.AllowAnonymousLogin;
											break;

										default:
											writeln("Unknown MQTT broker flag: ", flag);
									}
								}
								break;

							case "credentials":
								foreach (ref cred; opt.subItems)
								{
									MQTTClientCredentials clientCreds = MQTTClientCredentials(cred.name.unQuote.idup, cred.value.unQuote.idup);

									foreach (ref list; cred.subItems) switch (list.name)
									{
										case "whitelist":
											assert(0); // whitelist topics
											break;

										case "blacklist":
											assert(0); // blackist topics
											break;

										default:
											writeln("Invalid token: ", mqtt.name);
									}
									options.clientCredentials ~= clientCreds;
								}
								break;

							case "client-timeout-override":
								options.clientTimeoutOverride = opt.value.to!uint;
								break;

							default:
								writeln("Invalid token: ", mqtt.name);
						}

						broker = new MQTTBroker(options);
						broker.start();
						break;

					default:
						writeln("Invalid token: ", mqtt.name);
				}
				break;
+/
			default:
				// check to see if item name matches a plugin
				Plugin.Instance plugin = moduleInstance(confItem.name);
				if (plugin)
					plugin.parseConfig(confItem);
				else
					writeln("Invalid token: ", confItem.name);
		}
	}
}
