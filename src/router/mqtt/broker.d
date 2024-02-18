module router.mqtt.broker;

import core.sync.mutex;

import std.range : empty;

import router.mqtt.client;
import router.stream;

struct MQTTClientCredentials
{
	string username;
	string password;
	string[] whitelist;
	string[] blacklist;
}

struct MQTTBrokerOptions
{
	enum Flags
	{
		None = 0,
		AllowAnonymousLogin = 1 << 0,
	}

	ushort port = 1883;
	Flags flags = Flags.None;
	MQTTClientCredentials[] clientCredentials;
	uint clientTimeoutOverride = 0;	// maximum time since last contact before client is presumed awol
}

class MQTTBroker
{
	TCPServer server;
	Stream[] newConnections;
	Client[] clients;
	Mutex mutex;

	const MQTTBrokerOptions options;

	this(ref MQTTBrokerOptions options = MQTTBrokerOptions())
	{
		this.options = options;
		mutex = new Mutex;
		server = new TCPServer(options.port, &newConnection, cast(void*)this);
	}

	void start()
	{
		server.start();
	}

	void stop()
	{
		server.stop();
	}

	void update()
	{
		mutex.lock();
		while (!newConnections.empty)
		{
			clients ~= Client(this, newConnections[0]);
			newConnections = newConnections[1 .. $];
		}
		mutex.unlock();

		foreach (ref client; clients)
		{
			if (!client.update())
			{
				// destroy client...
			}
		}
	}

private:
	static void newConnection(TCPStream client, void* userData)
	{
		MQTTBroker _this = cast(MQTTBroker)userData;

		client.setOpts(StreamOptions.NonBlocking);

		_this.mutex.lock();
		_this.newConnections ~= client;
		_this.mutex.unlock();
	}
}
