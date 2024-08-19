module router.server;

import std.stdio;

import manager.element;
import manager.value;

import urt.log;
import urt.string;
import urt.time;

enum ServerType : uint
{
	Modbus = 0x00F0D805,
}

enum RequestStatus
{
	Success,
	Pending,
	Timeout,
	Error
};

class Request
{
	alias ResponseHandler = void delegate(Response response, void[] userData);

	MonoTime requestTime;
	ResponseHandler responseHandler;
	void[] userData;

	this(ResponseHandler responseHandler, void[] userData = null)
	{
		this.responseHandler = responseHandler;
		this.userData = userData;
	}

//	ValueDesc*[] readValues() const { return null; }
//	Value[] writeValues() const { return null; }

	override string toString() const
	{
		import std.format;
		return format("%s", cast(void*)this);
	}
}

class Response
{
	RequestStatus status;
	Server server;
	Request request;
	MonoTime responseTime;

	KVP[string] values() { return null; }

	Duration latency() const { return responseTime - request.requestTime; }

	override string toString()
	{
		import std.format;

		assert(request);

		if (status == RequestStatus.Timeout)
			return format("%s: TIMEOUT (%s)", cast(void*)this, server.name);
		else if (status == RequestStatus.Error)
			return format("%s: ERROR (%s)", cast(void*)this, server.name);
		return format("%s: RESPONSE (%s) - ", request, server.name, values);
	}

	struct KVP
	{
		string element;
		Value value;
	}
}


class Server
{
	this(string name)
	{
		this.name = name;
	}

	bool linkEstablished()
	{
		return false;
	}

	bool sendRequest(Request request)
	{
		request.requestTime = getTime();

		// request data by high-level id
		return false;
	}

	void poll()
	{
/+
		// check if any requests have timed out...
		MonoTime now = MonoTime.currTime;

		for (size_t i = 0; i < pendingRequests.length; )
		{
			if (pendingRequests[i].request.requestTime + requestTimeout < now)
			{
				Request request = pendingRequests[i].request;
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;

				writeInfo(now.printTime, " - Request timeout ", cast(void*)request, ", elapsed: ", now - request.requestTime);

				Response response = new Response();
				response.status = RequestStatus.Timeout;
				response.server = this;
				response.request = request;
				response.responseTime = now;

				request.responseHandler(response, request.userData);
			}
			else
				++i;
		}
+/
	}

	Request popPendingRequest(ushort requestId)
	{
		if (pendingRequests.length == 0)
			return null;

		Request request = null;
		size_t i = 0;
		for (; i < pendingRequests.length; ++i)
		{
			if (pendingRequests[i].requestId == requestId)
			{
				request = pendingRequests[i].request;
				if (i < pendingRequests.length - 1)
					pendingRequests[i] = pendingRequests[$ - 1];
				--pendingRequests.length;
				return request;
			}
		}
		return null;
	}

	void requestElements(Element*[] elements)
	{
		//...
	}

	struct PendingRequest
	{
		ushort requestId;
		Request request;
	}

	string name;
	ServerType devType;
	Duration requestTimeout;
	PendingRequest[] pendingRequests;
}
