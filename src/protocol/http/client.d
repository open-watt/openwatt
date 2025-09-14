module protocol.http.client;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.mem.allocator;
import urt.meta;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import manager;
import manager.base;

import protocol.http;
import protocol.http.message;

import router.stream;
import router.stream.tcp;

//version = DebugHTTPMessageFlow;

nothrow @nogc:

class HTTPClient : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("remote", remote)(),
                                         Property.create!("stream", stream)() ];
nothrow @nogc:

    alias TypeName = StringLit!"http-client";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!HTTPClient, name.move, flags);
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

    override bool validate() const pure
        => (!_host.empty || _remote != InetAddress()) != !!_stream; // TODO: validate URL??

    override CompletionStatus validating()
    {
        _stream.try_reattach();
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (!_stream)
        {
            if (!_host && _remote == InetAddress())
                return CompletionStatus.Error;

            const(char)[] stream_name = get_module!StreamModule.streams.generate_name(name);
            if (_host)
            {
                const(char)[] host = _host[];
                const(char)[] protocol = "http";

                size_t prefix = host.findFirst(":");
                if (prefix != host.length)
                {
                    protocol = host[0 .. prefix];
                    host = host[prefix + 1 .. $];
                }
                if (host.startsWith("//"))
                    host = host[2 .. $];

                const(char)[] resource;
                size_t res_offset = host.findFirst("/");
                if (res_offset != host.length)
                {
                    resource = host[res_offset .. $];
                    host = host[0 .. res_offset];
                }

                // TODO: I don't think we need a resource when connecting?
                //       maybe we should keep it and make all requests relative to this resource?

                if (protocol.icmp("http") == 0)
                {
                    ushort port = 80;

                    // see if host has a port...
                    size_t colon = host.findFirst(":");
                    if (colon != host.length)
                    {
                        const(char)[] portStr = host[colon + 1 .. $];
                        host = host[0 .. colon];

                        size_t taken;
                        long i = portStr.parse_int(&taken);
                        if (i > ushort.max || taken != portStr.length)
                            return CompletionStatus.Error; // invalid port string!
                    }

                    TCPStream tcp_stream = get_module!TCPStreamModule.tcp_streams.create(stream_name.makeString(defaultAllocator), ObjectFlags.Dynamic);
                    tcp_stream.remote = host.makeString(defaultAllocator);
                    tcp_stream.port = port;
                    _stream = tcp_stream;
                }
                else if (protocol.icmp("https") == 0)
                {
                    assert(false, "TODO: need TLS stream");
//                    stream = g_app.allocator.allocT!SSLStream(name, host, ushort(0));
//                    get_module!StreamModule.addStream(stream);
                }
            }
            else
            {
                TCPStream tcp_stream = get_module!TCPStreamModule.tcp_streams.create(stream_name.makeString(defaultAllocator), ObjectFlags.Dynamic);
                tcp_stream.remote = _remote;
                _stream = tcp_stream;
            }

            // we should have created a stream...
            if (!_stream)
            {
                assert(false, "error strategy... just write log output?");
                return CompletionStatus.Error;
            }
        }

        if (_stream.running)
            return CompletionStatus.Complete;
        return CompletionStatus.Continue;
    }

    override CompletionStatus shutdown()
    {
        if (_host || _remote != InetAddress())
        {
            _stream.destroy();
            _stream = null;
        }
        return CompletionStatus.Complete;
    }

    override void update()
    {
        if (requests.empty)
            return;

        int result = parser.update(stream);
        if (result != 0)
        {
            stream.disconnect();
            return;
        }

        bool sendNext = false;
        // check for request timeouts...
        MonoTime now = getTime();
        for (size_t i = 0; i < requests.length; )
        {
            HTTPMessage* r = requests[i];
            if (now - r.request_time > 5.seconds)
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

    HTTPMessage* request(HTTPMethod method, const(char)[] resource, HTTPMessageHandler response_handler, const void[] content = null, HTTPParam[] params = null, HTTPParam[] additional_headers = null, String username = null, String password = null)
    {
        if (!running)
            return null;

        HTTPMessage* request = defaultAllocator().allocT!HTTPMessage();
        request.http_version = server_version;
        request.method = method;
        request.url = resource.makeString(defaultAllocator);
        request.username = username.move;
        request.password = password.move;
        request.content = cast(ubyte[])content;
        request.headers = additional_headers.move;
        request.query_params = params.move;
        request.response_handler = response_handler;
        request.request_time = getSysTime();

        if (requests.length == 0) // OR CONCURRENT REQUESTS...
            send_request(*request);

        requests ~= request;
        return request;
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
        bool include_body = true;
        if (request.method == HTTPMethod.HEAD || request.method == HTTPMethod.TRACE || request.method == HTTPMethod.CONNECT)
            include_body = false;
        if (include_body && request.content.length == 0 && !(request.flags & HTTPFlags.ForceBody))
            include_body = false;

        // build the query string
        MutableString!0 get;
        foreach (ref q; request.query_params)
        {
            bool first = get.empty;

            size_t keyLen = q.key.url_encode_length();
            size_t valLen = q.value.url_encode_length();
            char[] ext = get.extend(keyLen + valLen + 2);

            if (first)
                ext[0] = '?';
            else
                ext[0] = '&';
            if (q.key.url_encode(ext[1 .. 1 + keyLen]) != keyLen)
                return; // bad encoding!
            ext = ext[1 + keyLen .. $];
            ext[0] = '=';
            if (q.value.url_encode(ext[1 .. 1 + valLen]) != valLen)
                return; // bad encoding!
        }

        MutableString!0 message;
        message.concat(enum_keys!HTTPMethod[request.method], ' ', request.url, get, " HTTP/", request.http_version >> 4, '.', request.http_version & 0xF,
                       "\r\nHost: ", _host,
                       "\r\nUser-Agent: OpenWatt\r\nAccept-Encoding: gzip, deflate\r\n");
        if (request.http_version == HTTPVersion.V1_1)
            message.append("Connection: keep-alive\r\n");

        if (request.username || request.password)
        {
            if (!(request.username && request.password))
                return; // must have both or neither

            message ~= "Authorization: Basic ";

            const(char)[] auth = tconcat(request.username, ':', request.password);
            auth.base64_encode(message.extend(base64_encode_length(auth.length)));
        }

        if (include_body)
        {
            message.append("Content-Length: ", request.content.length, "\r\n");
            // TODO: how do we determine the content type?
//            message.append("Content-Type: application/x-www-form-urlencoded\r\n");
        }
        foreach (ref h; request.headers)
            message.append(h.key, ": ", h.value, "\r\n");
        message ~= "\r\n";

        if (include_body)
            message ~= cast(char[])request.content[];

        ptrdiff_t r = stream.write(message);
        if (r != message.length)
        {
            assert(false, "TODO: handle error!");
        }

        version (DebugHTTPMessageFlow) {
            import urt.log;
            writeDebug("HTTP: request to ", host, " - ", enum_keys!HTTPMethod[request.method], " ", request.url, " (", request.content.length, " bytes)");
        }
    }

    int dispatch_message(ref const HTTPMessage response)
    {
        version (DebugHTTPMessageFlow) {
            import urt.log;
            writeDebug("HTTP: response from ", host, " - ", response.statusCode, " (", response.content.length, " bytes)");
        }

        if (requests.empty)
            return -1;

        // if we should close the connection
        if (requests[0].http_version == HTTPVersion.V1_0 || requests[0].header("Connection") == "close")
            stream.disconnect();

        if (requests[0].response_handler)
            requests[0].response_handler(response);

        defaultAllocator().freeT(requests[0]);
        requests.popFront();

        if (requests.length > 0)
            send_request(*requests[0]);

        return 0;
    }
}
