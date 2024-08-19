module router.client;

import std.datetime : Duration, MonoTime, msecs;

import router.server;


class Client
{
	this(string name)
	{
		this.name = name;
	}

	bool linkEstablished()
	{
		return false;
	}

	void sendResponse(Response response, void[])
	{
		// send response
		//...
	}

	Request poll()
	{
		return null;
	}

public:
	string name;

	ServerType devType;
}
