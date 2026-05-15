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
import urt.result;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.http;
import protocol.http.message;

import router.stream;

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
    const(char)[] remote() const
    {
        auto r = _conn.remote_name();
        return r.empty ? null : tconcat(_tls ? "https://" : "http://", r);
    }
    void remote(InetAddress value)
    {
        _conn.remote(value);
        _tls = false;
        _stream = null;
        restart();
    }
    StringResult remote(String value)
    {
        auto url = decompose_http_url(value[]);
        bool tls;
        if (url.scheme.empty || url.scheme.icmp("http") == 0)
            tls = false;
        else if (url.scheme.icmp("https") == 0)
            tls = true;
        else
            return StringResult(tconcat("unsupported scheme '", url.scheme, "' (expected http or https)"));
        if (url.host.empty)
            return StringResult("host cannot be empty");

        auto r = _conn.remote(url.host.makeString(defaultAllocator));
        if (r.failed)
            return r;
        _tls = tls;
        _stream = null;
        restart();
        return StringResult.success;
    }

    inout(Stream) stream() inout pure
        => _stream;
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (_stream is value)
            return null;
        _conn.clear_remote();
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
        request.request_target = resource.makeString(defaultAllocator);
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
        => _conn.has_remote() != !!_stream; // URL xor external stream

    override CompletionStatus startup()
    {
        if (!_stream && _conn.has_remote())
        {
            ushort default_port = _tls ? 443 : 80;
            if (!_conn.start(this, default_port, _tls))
                return CompletionStatus.error;
            _stream = _conn.get;
        }
        if (!_stream)
            return CompletionStatus.error;
        if (_stream.running)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_conn.has_remote())
        {
            _conn.stop();
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
    ClientConnection _conn;
    bool _tls;

    HTTPVersion server_version = HTTPVersion.V1_1;

    HTTPParser parser;
    Array!(HTTPMessage*) requests;

    void send_request(ref HTTPMessage request)
    {
        Array!char message = request.format_message(_conn.host[]);
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
        {
            import urt.meta.enuminfo;
            writeDebug("HTTP: request to ", _conn.host, " - ", enum_key_from_value!HTTPMethod(request.method), " ", request.request_target, " (", request.content.length, " bytes)");
        }
    }

    int dispatch_message(ref const HTTPMessage response)
    {
        version (DebugHTTPMessageFlow)
            writeDebug("HTTP: response from ", _conn.host, " - ", response.status_code, " (", response.content.length, " bytes)");

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
