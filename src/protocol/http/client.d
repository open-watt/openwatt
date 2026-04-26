module protocol.http.client;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.meta;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.http;
import protocol.http.message;
import protocol.http.tls;

import router.stream;
import router.stream.tcp;

//version = DebugHTTPMessageFlow;

nothrow @nogc:

class HTTPClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("stream", stream));
nothrow @nogc:

    enum type_name = "http-client";
    enum path = "/protocol/http/client";
    enum collection_id = CollectionType.http_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!HTTPClient, id, flags);
        parser = HTTPParser(&dispatch_message);
    }

    // Properties...
    ref const(String) remote() const pure
        => _host;
    void remote(InetAddress value)
    {
        _host = null;
        if (value == _remote)
            return;
        _remote = value;

        restart();
    }
    const(char)[] remote(String value)
    {
        if (value.empty)
            return "remote cannot be empty";
        if (value == _host)
            return null;

        _host = value.move;
        _remote = InetAddress();

        restart();
        return null;
    }

    inout(Stream) stream() inout pure
        => _stream;
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (_stream is value)
            return null;
        _stream = value;

        restart();
        return null;
    }

    // API...

    HTTPMessage* request(HTTPMethod method, const(char)[] resource, HTTPMessageHandler response_handler, const void[] content = null, HTTPParam[] params = null, HTTPParam[] additional_headers = null, String username = null, String password = null)
    {
        if (!running)
            return null;

        HTTPMessage* request = defaultAllocator().allocT!HTTPMessage();
        request.http_version = server_version;
        request.method = method;
        request.url = resource.makeString(defaultAllocator);
        request.request_target = request.url;
        request.username = username.move;
        request.password = password.move;
        request.content = cast(ubyte[])content;
        request.headers = additional_headers.move;
        request.query_params = params.move;
        request.response_handler = response_handler;
        request.timestamp = getSysTime();

        if (requests.length == 0) // OR CONCURRENT REQUESTS...
            send_request(*request);

        requests ~= request;
        return request;
    }


protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => (!_host.empty || _remote != InetAddress()) != !!_stream; // TODO: validate URL??

    override CompletionStatus startup()
    {
        if (!_stream)
        {
            if (!_host && _remote == InetAddress())
                return CompletionStatus.error;

            const(char)[] stream_name = Collection!Stream().generate_name(name[]);
            const(char)[] resource;
            _stream = create_http_stream(stream_name, _host[], _remote, resource);
            if (!_stream)
            {
                assert(false, "error strategy... just write log output?");
                return CompletionStatus.error;
            }
        }

        if (_stream.running)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_host || _remote != InetAddress())
        {
            _stream.destroy();
            _stream = null;
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        if (requests.empty)
            return;

        int result = parser.update(stream);
        if (result != 0)
        {
            restart();
            return;
        }

        bool sendNext = false;
        // check for request timeouts...
        MonoTime now = getTime();
        for (size_t i = 0; i < requests.length; )
        {
            HTTPMessage* r = requests[i];
            if (now - r.timestamp > 5.seconds)
            {
                requests.remove(i);
                defaultAllocator().freeT(r);
                sendNext = true;
            }
            else
                ++i;
        }

        if (sendNext && requests.length > 0)
            send_request(*requests[0]);
    }

private:
    ObjectRef!Stream _stream;
    String _host;
    InetAddress _remote;

    HTTPVersion server_version = HTTPVersion.V1_1;

    HTTPParser parser;
    Array!(HTTPMessage*) requests;

    void send_request(ref HTTPMessage request)
    {
        Array!char message = request.format_message(http_host_header(_host[]));
        if (message.empty)
            return;
        ptrdiff_t r = stream.write(message[]);
        if (r != message.length)
        {
            writeWarning("HTTP client: write failed (", r, " of ", message.length, " bytes)");
            restart();
            return;
        }

        version (DebugHTTPMessageFlow)
            writeDebug("HTTP: request to ", _host, " - ", enum_key_from_value!HTTPMethod(request.method), " ", request.url, " (", request.content.length, " bytes)");
    }

    int dispatch_message(ref const HTTPMessage response)
    {
        version (DebugHTTPMessageFlow)
            writeDebug("HTTP: response from ", _host, " - ", response.status_code, " (", response.content.length, " bytes)");

        if (requests.empty)
            return -1;

        bool should_close = requests[0].http_version == HTTPVersion.V1_0 || requests[0].header("Connection") == "close";

        if (requests[0].response_handler)
            requests[0].response_handler(response);

        defaultAllocator().freeT(requests[0]);
        requests.popFront();

        if (should_close)
        {
            restart();
            return 0;
        }

        if (requests.length > 0)
            send_request(*requests[0]);

        return 0;
    }
}
