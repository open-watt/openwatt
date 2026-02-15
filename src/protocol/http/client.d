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
import manager.collection;

import protocol.http;
import protocol.http.message;
import protocol.http.tls;

import router.stream;
import router.stream.tcp;

//version = DebugHTTPMessageFlow;

nothrow @nogc:

class HTTPClient : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("remote", remote)(),
                                         Property.create!("stream", stream)() ];
nothrow @nogc:

    enum type_name = "http-client";

    this(String name, ObjectFlags flags = ObjectFlags.none)
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
                return CompletionStatus.error;

            const(char)[] stream_name = get_module!StreamModule.streams.generate_name(name[]);
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

                // see if host has a port...
                ushort port;
                size_t colon = host.findFirst(":");
                if (colon != host.length)
                {
                    size_t taken;
                    long i = host[colon + 1 .. $].parse_int(&taken);
                    if (i > ushort.max || taken != host.length - colon - 1)
                        return CompletionStatus.error; // bad address!
                    port = cast(ushort)i;
                }

                if (protocol.icmp("http") == 0)
                {
                    if (port == 0)
                        port = 80;
                    _stream = get_module!TCPStreamModule.tcp_streams.create(stream_name, ObjectFlags.dynamic, NamedArgument("port", port), NamedArgument("remote", host));
                }
                else if (protocol.icmp("https") == 0)
                {
                    if (port == 0)
                        host = tconcat(host, ":443");
                    _stream = get_module!HTTPModule.tls_streams.create(stream_name, ObjectFlags.dynamic, NamedArgument("remote", host));
                }
            }
            else
            {
                // connecting to IP; assume http (https requires hostname for certificate)
                InetAddress addr = _remote;
                if (addr.family == AddressFamily.ipv6 && addr._a.ipv6.port == 0)
                    addr._a.ipv6.port = 80;
                else if (addr.family == AddressFamily.ipv4 && addr._a.ipv4.port == 0)
                    addr._a.ipv4.port = 80;
                _stream = get_module!TCPStreamModule.tcp_streams.create(stream_name, ObjectFlags.dynamic, NamedArgument("remote", addr));
            }

            // we should have created a stream...
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
            stream.disconnect();
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
        request.timestamp = getSysTime();

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
        Array!char message = request.format_message(_host[]);
        if (message.empty)
            return;
        ptrdiff_t r = stream.write(message[]);
        if (r != message.length)
        {
            assert(false, "TODO: handle error!");
        }

        version (DebugHTTPMessageFlow) {
            import urt.log;
            writeDebug("HTTP: request to ", _host, " - ", enum_key_from_value!HTTPMethod(request.method), " ", request.url, " (", request.content.length, " bytes)");
        }
    }

    int dispatch_message(ref const HTTPMessage response)
    {
        version (DebugHTTPMessageFlow) {
            import urt.log;
            writeDebug("HTTP: response from ", _host, " - ", response.status_code, " (", response.content.length, " bytes)");
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
