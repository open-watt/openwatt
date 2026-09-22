module protocol.http.client;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.mem;
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
import protocol.ip.client : IPClient;

import router.stream;

//version = DebugHTTPMessageFlow;

nothrow @nogc:

final class HTTPClient : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("remote", remote),
                                 Prop!("stream", stream),
                                 Prop!("timeout", timeout));
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
        mark_set!(typeof(this), [ "remote", "stream" ])();
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

        auto r = _conn.remote(url.host.make_string());
        if (r.failed)
            return r;
        _tls = tls;
        _stream = null;
        mark_set!(typeof(this), [ "remote", "stream" ])();
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
        mark_set!(typeof(this), [ "stream", "remote" ])();
        restart();
        return null;
    }

    Duration timeout() const pure
        => _timeout;
    void timeout(Duration value)
    {
        _timeout = value;
        mark_set!(typeof(this), "timeout")();
    }

    // API...

    HTTPMessage* request(HTTPMethod method, const(char)[] resource, HTTPMessageHandler response_handler, const void[] content = null, HTTPParam[] params = null, HTTPParam[] additional_headers = null, String username = null, String password = null)
    {
        if (!running)
            return null;

        HTTPMessage* request = alloc!HTTPMessage();
        request.http_version = server_version;
        request.method = method;
        request.request_target = resource.make_string();
        request.username = username.move;
        request.password = password.move;
        request.content = cast(ubyte[])content;
        request.headers = additional_headers.move;
        request.query_params = params.move;
        request.response_handler = response_handler;
        request.timestamp = getSysTime();

        requests ~= request;
        if (requests.length == 1 && !_dispatching)
            send_request(*request);
        return running ? request : null;
    }


protected:

    override bool validate() const pure
        => _conn.has_remote() != !!_stream; // URL xor external stream

    override CompletionStatus startup()
    {
        parser = HTTPParser(&dispatch_message);
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
        foreach (request; requests)
            free(request);
        requests.clear();
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
        if (!running)
            return;
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
            if (now - r.timestamp > _timeout)
            {
                sendNext |= i == 0;
                HTTPMessage empty;
                complete_request(i, empty);
                if (!running)
                    return;
            }
            else
                ++i;
        }

        if (sendNext && requests.length > 0)
            send_request(*requests[0]);
    }

private:
    ObjectRef!Stream _stream;
    IPClient _conn;
    Duration _timeout = 5.seconds;
    bool _tls;
    bool _dispatching;

    HTTPVersion server_version = HTTPVersion.V1_1;

    HTTPParser parser;
    Array!(HTTPMessage*) requests;

    void complete_request(size_t index, ref const HTTPMessage response)
    {
        HTTPMessage* request = requests[index];
        requests.remove(index);
        scope (exit) free(request);
        _dispatching = true;
        scope (exit) _dispatching = false;
        if (request.response_handler)
            request.response_handler(response);
    }

    void send_request(ref HTTPMessage request)
    {
        Array!char message = request.format_message(_conn.host[]);
        if (message.empty)
            return;
        ptrdiff_t r = stream.write(message[]);
        if (!running)
            return;
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

        complete_request(0, response);
        if (!running)
            return 1;

        if (should_close)
        {
            restart();
            return 1;
        }

        if (requests.length > 0)
            send_request(*requests[0]);

        return running ? 0 : 1;
    }
}

unittest
{
    static class TestStream : Stream
    {
    nothrow @nogc:
        enum type_name = "http-test-stream";
        const(ubyte)[] input;
        uint reads, writes;
        bool fail_write;
        this(CID id, ObjectFlags flags = ObjectFlags.none) { super(collection_type_info!TestStream, id, flags); }
        void activate() { set_state(State.running); }
        override ptrdiff_t read(void[] buffer)
        {
            ++reads;
            size_t count = min(buffer.length, input.length);
            (cast(ubyte[])buffer)[0 .. count] = input[0 .. count];
            input = input[count .. $];
            return count;
        }
        override ptrdiff_t write(const(void[])[] data...)
        {
            ++writes;
            if (fail_write)
                return -1;
            size_t count;
            foreach (part; data)
                count += part.length;
            return count;
        }
    }

    static struct Handler
    {
    nothrow @nogc:
        HTTPClient client;
        bool timeout, destroy_client;
        uint calls;
        int stop(ref const HTTPMessage response)
        {
            ++calls;
            assert(response.status_code == (timeout ? 0 : 200));
            if (destroy_client)
                client.destroy();
            else
                client.restart();
            return 0;
        }
        int enqueue(ref const HTTPMessage response)
        {
            ++calls;
            assert(client.requests.empty);
            assert(client.request(HTTPMethod.GET, "/next", null) !is null);
            return 0;
        }
    }

    foreach (timeout; [false, true])
        foreach (destroy_client; [false, true])
        {
            TestStream wire = Collection!TestStream().alloc("http-callback-wire");
            Collection!TestStream().add(wire);
            wire.activate();
            HTTPClient client = Collection!HTTPClient().alloc("http-callback-client");
            Collection!HTTPClient().add(client);
            client.stream(wire);
            Collection!HTTPClient().update_all();
            assert(client.running);
            Handler handler = Handler(client, timeout, destroy_client);
            client.request(HTTPMethod.GET, "/first", &handler.stop);
            client.request(HTTPMethod.GET, "/second", &handler.stop);
            if (timeout)
                foreach (request; client.requests)
                    request.timestamp = getSysTime() - 10.seconds;
            else
                wire.input = cast(const(ubyte)[])("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                    ~ "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
            client.update();
            assert(handler.calls == 1 && wire.reads == 1 && wire.writes == 1 && client.requests.empty && !client.running);
            if (!destroy_client)
            {
                wire.input = null;
                Collection!HTTPClient().update_all();
                assert(client.running);
                client.update();
                assert(handler.calls == 1);
                client.destroy();
            }
            wire.destroy();
            Collection!HTTPClient().update_all();
            Collection!Stream().update_all();
        }

    foreach (timeout; [false, true])
    {
        TestStream wire = Collection!TestStream().alloc("http-enqueue-wire");
        Collection!TestStream().add(wire);
        wire.activate();
        HTTPClient client = Collection!HTTPClient().alloc("http-enqueue-client");
        Collection!HTTPClient().add(client);
        client.stream(wire);
        Collection!HTTPClient().update_all();
        Handler handler = Handler(client);
        auto request = client.request(HTTPMethod.GET, "/first", &handler.enqueue);
        if (timeout)
            request.timestamp = getSysTime() - 10.seconds;
        else
            wire.input = cast(const(ubyte)[])"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
        client.update();
        assert(handler.calls == 1 && wire.writes == 2 && client.requests.length == 1);
        client.request(HTTPMethod.GET, "/expired-queued", null).timestamp = getSysTime() - 10.seconds;
        client.update();
        assert(wire.writes == 2 && client.requests.length == 1);
        client.restart();
        assert(client.requests.empty);
        Collection!HTTPClient().update_all();
        wire.fail_write = true;
        assert(client.request(HTTPMethod.GET, "/failed", null) is null);
        assert(!client.running && client.requests.empty);
        client.destroy();
        wire.destroy();
        Collection!HTTPClient().update_all();
        Collection!Stream().update_all();
    }
}
