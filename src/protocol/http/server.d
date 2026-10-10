module protocol.http.server;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.pagepool : Page, page_alloc, page_free;
import urt.mem.temp : talloc_array;
import urt.string;
import urt.string.format : tconcat, tstring;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.features;

static if (has_tls)
    import protocol.tls : Certificate;

import protocol.http;
import protocol.http.message;

import protocol.ip.tcp_stream;
import router.iface;
import router.stream;

version = DebugHTTPServer;

nothrow @nogc:


final class HTTPServer : ActiveObject
{
nothrow @nogc:

    ~this() {}

    enum type_name = "http-server";
    enum path = "/protocol/http/server";
    enum collection_id = CollectionType.http_server;

    alias RequestHandler = int delegate(ref const HTTPMessage, ref Stream stream, const(ubyte)[] leftover) nothrow @nogc;
    alias StreamingRequestBegin = StreamingChunkHandler delegate(ref const HTTPMessage, ref Stream stream) nothrow @nogc;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!HTTPServer, id, flags);
    }

    ushort port() const pure
        => _port;
    const(char)[] port(ushort value)
    {
        if (_port == value)
            return null;
        _port = value;
        mark_set!(typeof(this), "port")();

        if (_server)
            _server.port = _port;
        return null;
    }

    static if (has_tls)
    ushort tls_port() const pure
        => _tls_port;
    static if (has_tls)
    const(char)[] tls_port(ushort value)
    {
        if (_tls_port == value)
            return null;
        _tls_port = value;
        mark_set!(typeof(this), "tls-port")();

        if (_tls_server)
            _tls_server.port = _tls_port;
        return null;
    }

    static if (has_tls)
    const(char)[][] certificates() const
    {
        auto buf = talloc_array!(const(char)[])(_certificates.length);
        size_t n = 0;
        foreach (ref c; _certificates)
        {
            if (c)
                buf[n++] = c.name[];
        }
        return buf[0 .. n];
    }
    static if (has_tls)
    void certificates(Certificate[] value)
    {
        if (_cert_subscribed)
        {
            foreach (ref c; _certificates)
                if (c) c.unsubscribe(&cert_state_change);
            _cert_subscribed = false;
        }
        _certificates.clear();
        _certificates.reserve(value.length);
        foreach (c; value)
            _certificates.emplaceBack(c);
        mark_set!(typeof(this), "certificates")();
        restart();
    }

    static if (has_tls)
    bool https_redirect() const pure
        => _https_redirect;
    static if (has_tls)
    void https_redirect(bool value)
    {
        _https_redirect = value;
        mark_set!(typeof(this), "https-redirect")();
    }

    size_t max_request_body() const pure
        => _max_request_body;
    void max_request_body(size_t value)
    {
        _max_request_body = value;
        mark_set!(typeof(this), "max-request-body")();
        foreach (s; _sessions)
            s.parser.max_buffered_body = value;
    }

    const(char)[] allowed_origin() const pure
        => _allowed_origin[];
    void allowed_origin(const(char)[] value)
    {
        _allowed_origin = value.make_string();
        mark_set!(typeof(this), "allowed-origin")();
    }

    bool add_cors(ref HTTPMessage response, ref const HTTPMessage request, String* override_origin = null)
        => add_cors(response, request.header("Origin")[], override_origin);

    bool add_cors(ref HTTPMessage response, const(char)[] request_origin, String* override_origin = null)
    {
        String* allowed = override_origin ? override_origin : &_allowed_origin;
        if (allowed.empty)
            return false;

        if ((*allowed)[] == "*")
        {
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Origin", StringLit!"*");
            return true;
        }

        if (request_origin != (*allowed)[])
            return false;

        response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Origin", *allowed);
        response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Credentials", StringLit!"true");
        response.headers ~= HTTPParam(StringLit!"Vary", StringLit!"Origin");
        return true;
    }

    static if (has_tls)
        alias Properties = AliasSeq!(Prop!("port", port),
                                     Prop!("tls-port", tls_port),
                                     Prop!("certificates", certificates),
                                     Prop!("https-redirect", https_redirect),
                                     Prop!("max-request-body", max_request_body),
                                     Prop!("allowed-origin", allowed_origin));
    else
        alias Properties = AliasSeq!(Prop!("port", port),
                                     Prop!("max-request-body", max_request_body),
                                     Prop!("allowed-origin", allowed_origin));

    void set_default_request_handler(RequestHandler default_request_handler)
    {
        _default_request_handler = default_request_handler;
    }

    // One registration claims a whole set of methods for the prefix, so a handler
    // that answers many (HTTPMethodSet.GET | HTTPMethodSet.HEAD, or `any`) costs
    // one entry rather than one per method.
    bool add_uri_handler(HTTPMethodSet methods, const(char)[] uri_prefix, RequestHandler request_handler)
    {
        foreach (ref h; _handlers)
        {
            if ((h.methods & methods) && h.uri_prefix[] == uri_prefix[])
                return false; // a method already claimed here; overlapping prefixes are fine (longest match wins)
        }
        _handlers ~= Handler(methods, uri_prefix.make_string(), request_handler);
        return true;
    }

    bool add_uri_handler(HTTPMethodSet methods, const(char)[] uri_prefix, StreamingRequestBegin begin_handler)
    {
        foreach (ref h; _handlers)
        {
            if ((h.methods & methods) && h.uri_prefix[] == uri_prefix[])
                return false; // a method already claimed here; overlapping prefixes are fine (longest match wins)
        }
        _handlers ~= Handler(methods, uri_prefix.make_string(), begin_handler);
        return true;
    }

    bool add_uri_handler(HTTPMethod method, const(char)[] uri_prefix, RequestHandler request_handler)
        => add_uri_handler(method.method_set, uri_prefix, request_handler);

    bool add_uri_handler(HTTPMethod method, const(char)[] uri_prefix, StreamingRequestBegin begin_handler)
        => add_uri_handler(method.method_set, uri_prefix, begin_handler);

    void remove_uri_handler(HTTPMethodSet methods, RequestHandler request_handler)
    {
        for (size_t i = 0; i < _handlers.length; )
        {
            if ((_handlers[i].methods & methods) && !_handlers[i].is_streaming && _handlers[i].buffered is request_handler)
            {
                _handlers[i].methods &= ~methods;
                if (_handlers[i].methods == 0)
                    _handlers.remove(i);
                else
                    ++i;
            }
            else
                ++i;
        }
    }

    void remove_uri_handler(HTTPMethodSet methods, StreamingRequestBegin begin_handler)
    {
        for (size_t i = 0; i < _handlers.length; )
        {
            if ((_handlers[i].methods & methods) && _handlers[i].is_streaming && _handlers[i].streaming is begin_handler)
            {
                _handlers[i].methods &= ~methods;
                if (_handlers[i].methods == 0)
                    _handlers.remove(i);
                else
                    ++i;
            }
            else
                ++i;
        }
    }

    void remove_uri_handler(HTTPMethod method, RequestHandler request_handler)
        => remove_uri_handler(method.method_set, request_handler);

    void remove_uri_handler(HTTPMethod method, StreamingRequestBegin begin_handler)
        => remove_uri_handler(method.method_set, begin_handler);

    RequestHandler hook_global_handler(RequestHandler request_handler)
    {
        RequestHandler old = _default_request_handler;
        _default_request_handler = request_handler;
        return old;
    }


protected:

    override bool validate() const pure
    {
        if (_port != 0)
            return true;
        static if (has_tls)
            return _tls_port != 0;
        else
            return false;
    }

    override CompletionStatus startup()
    {
        version (DebugHTTPServer)
        {
            static if (has_tls)
                log.trace("startup, port=", _port, " tls-port=", _tls_port, " certs=", _certificates.length);
            else
                log.trace("startup, port=", _port);
        }

        if (_port != 0 && !_server)
        {
            if (!try_start_http())
                return CompletionStatus.error;
        }

        static if (has_tls)
        {
            if (_tls_port != 0 && !_tls_server)
                try_start_tls();

            if (!_cert_subscribed && _certificates.length > 0)
            {
                foreach (ref c; _certificates)
                    if (c) c.subscribe(&cert_state_change);
                _cert_subscribed = true;

                version (DebugHTTPServer)
                    log.trace("subscribed to ", _certificates.length, " certificate(s)");
            }
        }

        bool http_up = (_port != 0) && _server && _server.running;
        static if (has_tls)
        {
            bool tls_up = (_tls_port != 0) && _tls_server && _tls_server.running;
            http_up = http_up || tls_up;
        }
        return http_up ? CompletionStatus.complete : CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        version (DebugHTTPServer)
            log.trace("shutdown, sessions=", _sessions.length);

        static if (has_tls)
        {
            if (_cert_subscribed)
            {
                foreach (ref c; _certificates)
                    if (c) c.unsubscribe(&cert_state_change);
                _cert_subscribed = false;
            }

            if (_tls_server)
            {
                _tls_server.unsubscribe(&server_state_change);
                _tls_server.destroy();
                _tls_server = null;
            }
        }
        if (_server)
        {
            _server.unsubscribe(&server_state_change);
            _server.destroy();
            _server = null;
        }

        while (!_sessions.empty)
        {
            Session* s = _sessions.popBack();
            s.close();
            free(s);
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
        for (size_t i = 0; i < _sessions.length; )
        {
            int result = _sessions[i].update();
            if (result != 0)
            {
                free(_sessions[i]);
                _sessions.remove(i);
            }
            else
                ++i;
        }
    }

private:
    struct Handler
    {
    nothrow @nogc:
        HTTPMethodSet methods;
        String uri_prefix;
        RequestHandler buffered;
        StreamingRequestBegin streaming;

        bool is_streaming() const pure
            => streaming !is null;

        this(HTTPMethodSet methods, String uri_prefix, RequestHandler buffered)
        {
            this.methods = methods;
            this.uri_prefix = uri_prefix.move;
            this.buffered = buffered;
        }

        this(HTTPMethodSet methods, String uri_prefix, StreamingRequestBegin streaming)
        {
            this.methods = methods;
            this.uri_prefix = uri_prefix.move;
            this.streaming = streaming;
        }
    }

    ushort _port;
    size_t _max_request_body = 64 * 1024;
    String _allowed_origin;
    RequestHandler _default_request_handler;

    TCPServer _server;
    Array!Handler _handlers;
    Array!(Session*) _sessions;

    static if (has_tls)
    {
        ushort _tls_port;
        bool _https_redirect;
        bool _cert_subscribed;
        TCPServer _tls_server;
        Array!(ObjectRef!Certificate) _certificates;
    }

    Session* session_of(Stream stream)
    {
        foreach (session; _sessions)
        {
            if (session.stream is stream)
                return session;
        }
        return null;
    }

    // a prefix matches at a path boundary: the target must equal the prefix, or continue
    // with '/'. The empty prefix (root) matches everything.
    static bool uri_prefix_match(const(char)[] target, const(char)[] prefix) pure
    {
        if (prefix.length == 0)
            return true;
        if (!target.startsWith(prefix))
            return false;
        if (target.length == prefix.length)
            return true;
        return prefix[$-1] == '/' || target[prefix.length] == '/';
    }

    // pick the handler with the longest matching prefix, so more-specific routes
    // (/api, /ws) take precedence over a broad one (/) regardless of registration order.
    ptrdiff_t find_handler(const(char)[] target, HTTPMethod method, bool streaming)
    {
        ptrdiff_t best = -1;
        size_t best_len = 0;
        foreach (i, ref h; _handlers)
        {
            if (h.is_streaming != streaming || !(h.methods & method.method_set))
                continue;
            if (!uri_prefix_match(target, h.uri_prefix[]))
                continue;
            if (best == -1 || h.uri_prefix.length > best_len)
            {
                best = i;
                best_len = h.uri_prefix.length;
            }
        }
        return best;
    }

    void accept_http_connection(Stream stream, ref const InetAddress remote, void*)
    {
        log.info("new HTTP session from ", remote);
        RequestHandler redirect;
        static if (has_tls)
            redirect = (_https_redirect && _tls_port != 0) ? &http_redirect_handler : null;
        _sessions.emplaceBack(alloc!Session(this, stream, redirect));
    }

    static if (has_tls)
    void accept_tls_connection(Stream stream, ref const InetAddress remote, void*)
    {
        _sessions.emplaceBack(alloc!Session(this, stream, null));
    }

    static if (has_tls)
    bool any_cert_valid()
    {
        foreach (ref c; _certificates)
            if (auto cert = dyn_cast!Certificate(c.get()))
                if (cert.is_valid)
                    return true;
        return false;
    }

    static if (has_tls)
    void push_certs_to_tls()
    {
        import protocol.tls : TLSServer;
        if (auto tls = dyn_cast!TLSServer(_tls_server))
            tls.set_certificate_array(_certificates[]);
    }

    bool try_start_http()
    {
        const(char)[] server_name = Collection!TCPServer().generate_name(tconcat(name[], "_tcp"));
        _server = Collection!TCPServer().create(server_name, ObjectFlags.dynamic, NamedArgument("port", _port));
        if (!_server)
        {
            log.error("failed to create HTTP listener");
            return false;
        }
        _server.set_connection_callback(&accept_http_connection, null);
        _server.subscribe(&server_state_change);
        log.notice("listening on HTTP port ", _port);
        return true;
    }

    static if (has_tls)
    void try_start_tls()
    {
        import protocol.tls : TLSServer;
        version (DebugHTTPServer)
            log.trace("try_start_tls, any_cert_valid=", any_cert_valid());
        if (!any_cert_valid())
            return;

        BaseObject[32] certs;
        size_t num_certs = 0;
        foreach (ref c; _certificates)
            if (auto cert = c.get())
                certs[num_certs++] = cert;

        const(char)[] tls_name = Collection!TLSServer().generate_name(tconcat(name[], "_tls"));
        _tls_server = Collection!TLSServer().create(tls_name, ObjectFlags.dynamic,
            NamedArgument("port", _tls_port), NamedArgument("certificates", certs[0 .. num_certs]));
        if (!_tls_server)
        {
            log.error("failed to create TLS listener");
            return;
        }
        _tls_server.set_connection_callback(&accept_tls_connection, null);
        _tls_server.subscribe(&server_state_change);
        log.notice("listening on HTTPS port ", _tls_port);
    }

    void server_state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.destroyed)
        {
            if (obj is _server)
            {
                log.warning("HTTP listener destroyed externally, recreating");
                _server = null;
                try_start_http();
            }
            static if (has_tls)
            {
                if (obj is _tls_server)
                {
                    log.warning("TLS listener destroyed externally, recreating");
                    _tls_server = null;
                    try_start_tls();
                }
            }
        }
    }

    static if (has_tls)
    void cert_state_change(ActiveObject obj, StateSignal signal)
    {
        version (DebugHTTPServer)
            log.trace("cert_state_change signal=", signal);

        if (signal == StateSignal.online)
        {
            if (!_tls_server && _tls_port != 0)
                try_start_tls();
            else if (_tls_server)
                push_certs_to_tls();
        }
        else if (signal == StateSignal.offline)
        {
            if (_tls_server)
            {
                if (!any_cert_valid())
                {
                    log.info("no valid certs remaining, shutting down TLS");
                    _tls_server.unsubscribe(&server_state_change);
                    _tls_server.destroy();
                    _tls_server = null;
                }
                else
                    push_certs_to_tls();
            }
        }
    }

    static if (has_tls)
    int http_redirect_handler(ref const HTTPMessage request, ref Stream stream, const(ubyte)[] leftover)
    {
        // allow ACME challenge paths
        if (request.request_target[].startsWith("/.well-known/acme-challenge/"))
            return 0;

        // build redirect location
        const(char)[] host = request.header("Host")[];
        if (host.empty)
        {
            foreach (ref c; _certificates)
            {
                if (auto cert = dyn_cast!Certificate(c.get()))
                {
                    if (cert.is_valid && !cert.domain[].empty)
                    {
                        host = cert.domain[];
                        break;
                    }
                }
            }
        }
        if (host.empty)
            return 0; // can't redirect without a host

        const(char)[] target = request.request_target[];
        const(char)[] location;
        if (_tls_port == 443)
            location = tconcat("https://", host, target);
        else
            location = tconcat("https://", host, ':', _tls_port, target);

        HTTPMessage response;
        response.http_version = request.http_version;
        response.status_code = 301;
        response.reason = StringLit!"Moved Permanently";
        response.headers ~= HTTPParam(StringLit!"Location", location.make_string());
        response.headers ~= HTTPParam(StringLit!"Content-Length", StringLit!"0");
        respond(stream, response);
        return 1;
    }

    struct Session
    {
    nothrow @nogc:

        this(HTTPServer server, Stream stream, RequestHandler redirect_handler)
        {
            this.server = server;
            this.stream = stream;
            this.redirect_handler = redirect_handler;
            stream.subscribe(&signal_handler);
            _subscribed = true;
            parser = HTTPParser(&request_callback);
            parser.headers_ready_handler = &headers_ready_callback;
            parser.max_buffered_body = server._max_request_body;
            stream.rx_handler(&on_data);
        }

        void close()
        {
            if (!stream)
                return;
            detach();
            stream.destroy();
            stream = null;
        }

        // never close here: that would free the stream inside its own recv callback.
        // Terminal conditions flag _finished; the tick sweep in update() reaps.
        void on_data(Stream s, const(void)[] data, MonoTime)
        {
            if (_finished || _deferred || !stream)
                return;
            int result = parser.feed(cast(const(ubyte)[])data, s);
            if (result < 0)
                _finished = true;
            else if (!stream)
            {
                // stream claimed (e.g. ws upgrade): drop our hooks so the new owner reads it
                s.release_rx_handler(&on_data);
                unsubscribe_signal(s);
                _finished = true;
            }
        }

        int update()
        {
            if (!stream)
                return -1;
            if (_finished)
            {
                close();
                return -1;
            }
            return 0;
        }

        int headers_ready_callback(ref const HTTPMessage request, out StreamingChunkHandler chunk_handler)
        {
            ptrdiff_t idx = server.find_handler(request.request_target[], request.method, true);
            if (idx >= 0)
            {
                StreamingRequestBegin begin = server._handlers[idx].streaming;
                chunk_handler = begin(request, stream);
                if (chunk_handler is null)
                    return -1;
            }
            return 0;
        }

        int request_callback(ref const HTTPMessage request)
        {
            const(ubyte)[] leftover = parser.current_leftover;

            if (redirect_handler)
            {
                int result = redirect_handler(request, stream, leftover);
                if (result != 0)
                    return result;
            }

            ptrdiff_t idx = server.find_handler(request.request_target[], request.method, false);
            if (idx >= 0)
            {
                RequestHandler handler = server._handlers[idx].buffered;
                int result = handler(request, stream, leftover);
                if (!stream)
                    return 1;
                if (_deferred)
                    return http_response_deferred;
                return result;
            }

            if (server._default_request_handler)
            {
                int result = server._default_request_handler(request, stream, leftover);
                if (!stream)
                    return 1;
                if (_deferred)
                    return http_response_deferred;
                return result;
            }

            HTTPMessage response = create_response(request.http_version, 404, StringLit!"text/plain", status_text(404)[]);
            .respond(stream, response);

            return 0;
        }

        HTTPServer server;
        Stream stream;
        RequestHandler redirect_handler;

    private:
        HTTPParser parser;
        Page* _out;
        SendHandler _body;
        ChunkedFilter _chunked;
        ResponseEnd _ended;
        bool _subscribed;
        bool _finished;
        bool _deferred;

        void defer_response()
        {
            assert(!_deferred);
            _deferred = true;
            stream.release_rx_handler(&on_data);
        }

        void resume_response()
        {
            assert(_deferred);
            _deferred = false;

            Stream s = stream;
            int result = parser.resume(s);
            if (result < 0)
                _finished = true;
            else if (!stream)
            {
                s.release_rx_handler(&on_data);
                unsubscribe_signal(s);
                _finished = true;
            }
            if (!_finished && !_deferred && stream)
                s.rx_handler(&on_data);
        }

        void unsubscribe_signal(Stream s)
        {
            if (!_subscribed)
                return;
            s.unsubscribe(&signal_handler);
            _subscribed = false;
        }

        void signal_handler(ActiveObject object, StateSignal signal)
        {
            if (signal != StateSignal.online)
            {
                detach();
                stream = null;
            }
        }

        void detach()
        {
            if (_out || _body)
                settle(false);
            else if (_deferred)
                g_app.cancel(&resume_parse);
            stream.release_tx_handler(&produce_response);
            stream.release_rx_handler(&on_data);
            unsubscribe_signal(stream);
        }

        bool respond(ref HTTPMessage head, SendHandler body_, bool with_body, ulong length, ResponseEnd ended)
        {
            if (!stream || _out || _body)
                return false;
            if (body_ && length == unknown_length && head.http_version < HTTPVersion.V1_1)
            {
                HTTPMessage refusal = create_response(head.http_version, 505, StringLit!"text/plain", status_text(505)[]);
                respond(refusal, null, true, refusal.content.length, null);
                if (ended)
                    ended(false);
                return true;
            }
            Array!char text = format_message_head(head, null, with_body, length);
            if (text.empty || !queue_out(text[]) || !queue_out(head.content[]))
            {
                free_out();
                return false;
            }
            _chunked = ChunkedFilter(body_);
            _body = body_ && length == unknown_length ? &_chunked.produce : body_;
            _ended = ended;
            stream.tx_handler(&produce_response);
            if ((_out || _body) && !_deferred)
                defer_response();
            return true;
        }

        Page* produce_response(ref const TxRequest req, out TxStatus status)
        {
            Page* page;
            if (_out)
            {
                page = take_tx_page(_out, req, status);
                if (page)
                    status = _out || _body ? TxStatus.more : TxStatus.end;
            }
            else if (_body)
                page = _body(req, status);
            else
                status = TxStatus.end;
            if (status == TxStatus.end || status == TxStatus.abort)
                settle(status == TxStatus.end);
            return page;
        }

        // the next request is parsed on the following pass, outside the pull that ended this response
        void settle(bool sent)
        {
            ResponseEnd ended = _ended;
            _body = null;
            _ended = null;
            free_out();
            if (ended)
                ended(sent);
            if (!sent)
                _finished = true;
            else if (_deferred)
                g_app.schedule(getTime(), &resume_parse);
        }

        void resume_parse(MonoTime)
        {
            if (_deferred && stream)
                resume_response();
        }

        bool queue_out(const(void)[] bytes)
        {
            while (bytes.length)
            {
                size_t n = bytes.length < max_tx_page ? bytes.length : max_tx_page;
                Page* page = page_alloc(n);
                if (!page)
                    return false;
                page.data[] = bytes[0 .. n];
                append_tx_chain(_out, page);
                bytes = bytes[n .. $];
            }
            return true;
        }

        void free_out()
        {
            while (_out)
            {
                Page* next = _out.next;
                page_free(_out);
                _out = next;
            }
        }
    }
}


alias ResponseEnd = void delegate(bool sent) nothrow @nogc;

// no further request is parsed until the body ends; HTTP/1.0 is answered 505 for a body of unknown length
bool respond(ref Stream stream, ref HTTPMessage head, SendHandler body_, ulong length, ResponseEnd ended = null)
{
    HTTPServer.Session* session = session_of(stream);
    return session && session.respond(head, body_, true, length, ended);
}

bool respond(ref Stream stream, ref HTTPMessage message)
{
    HTTPServer.Session* session = session_of(stream);
    return session && session.respond(message, null, body_included(message), message.content.length, null);
}

// the session parses no further request until the handler responds, later
bool respond_later(ref Stream stream)
{
    HTTPServer.Session* session = session_of(stream);
    if (session)
        session.defer_response();
    return session !is null;
}

struct ChunkedFilter
{
nothrow @nogc:
    SendHandler inner;

    Page* produce(ref const TxRequest req, out TxStatus status)
    {
        size_t grant = (req.bytes < max_tx_page ? req.bytes : max_tx_page) - size_line - trailer;
        Page* page = inner(TxRequest(grant, req.deadline, req.headroom + size_line, req.tailroom + trailer), status);
        if (page)
        {
            char[size_line] line = void;
            size_t n = format_uint(page.length, line[], 16);
            line[n .. n + 2] = "\r\n";
            n += 2;
            page.offset -= cast(ushort)n;
            page.length += cast(ushort)n;
            (cast(char[])page.data)[0 .. n] = line[0 .. n];
            append(page, "\r\n");
        }
        else if (status == TxStatus.end)
            page = alloc_tx_page(TxRequest(last.length, req.deadline, req.headroom, req.tailroom + last.length), 0, status);
        if (page && status == TxStatus.end)
            append(page, last);
        return page;
    }

private:
    enum size_line = 6;
    enum last = "0\r\n\r\n";
    enum trailer = 2 + last.length;

    static void append(Page* page, const(char)[] text)
    {
        (cast(char*)page)[page.offset + page.length .. page.offset + page.length + text.length] = text[];
        page.length += cast(ushort)text.length;
    }
}


private:

HTTPServer.Session* session_of(Stream stream)
{
    foreach (server; Collection!HTTPServer().values)
    {
        if (HTTPServer.Session* session = server.session_of(stream))
            return session;
    }
    return null;
}


unittest
{
    import urt.mem.pagepool : page_pool_deinit, page_pool_init;

    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();

    static struct Text
    {
    nothrow @nogc:
        const(char)[] text;

        Page* produce(ref const TxRequest req, out TxStatus status)
        {
            if (!text.length)
            {
                status = TxStatus.end;
                return null;
            }
            size_t n = text.length < req.bytes ? text.length : req.bytes;
            Page* page = alloc_tx_page(req, n, status);
            if (!page)
                return null;
            (cast(char[])page.data)[] = text[0 .. n];
            text = text[n .. $];
            if (!text.length)
                status = TxStatus.end;
            return page;
        }
    }

    static const(char)[] take(Page* page, ref Array!char output)
    {
        size_t at = output.length;
        output ~= cast(const(char)[])page.data;
        page_free(page);
        return output[at .. $];
    }

    // each page is framed as a chunk, and the page that ends the body carries the last chunk
    {
        char[60] body = 'x';
        Text text = Text(body[]);
        ChunkedFilter chunked = ChunkedFilter(&text.produce);
        TxRequest req = TxRequest(64);
        TxStatus status;
        Array!char output;
        Page* page = chunked.produce(req, status);
        assert(page.length <= req.bytes && status == TxStatus.more);
        const(char)[] chunk = take(page, output);
        assert(chunk[0 .. 4] == "33\r\n" && chunk[4 .. 55] == body[0 .. 51] && chunk[55 .. $] == "\r\n");
        page = chunked.produce(req, status);
        chunk = take(page, output);
        assert(status == TxStatus.end && chunk[0 .. 3] == "9\r\n" && chunk[3 .. 12] == body[0 .. 9] && chunk[12 .. $] == "\r\n0\r\n\r\n");

        // a body that ends with nothing left still closes with the last chunk
        Text empty;
        chunked = ChunkedFilter(&empty.produce);
        empty.text = "";
        page = chunked.produce(req, status);
        output.clear();
        assert(status == TxStatus.end && take(page, output) == "0\r\n\r\n");
    }

    static class Line : Stream
    {
    nothrow @nogc:
        enum type_name = "http-test-line";
        ~this() {}
        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Line, id, flags);
        }
        override ptrdiff_t write(const(void[])[] data...)
            => 0;
        override size_t tx_request() const
            => room;
        override void queue_tx_page(Page* page)
        {
            room -= page.length;
            take(page, output);
        }
        size_t room = size_t.max;
        Array!char output;
    }

    HTTPServer server = alloc!HTTPServer(CID(1));
    scope (exit) free(server);
    Line line = alloc!Line(CID(2));
    scope (exit) free(line);
    HTTPServer.Session session = HTTPServer.Session(server, line, null);

    // a response the line takes whole is sent before respond returns, and the next request is parsed at once
    HTTPMessage fixed = create_response(HTTPVersion.V1_1, 200, StringLit!"text/plain", "hello");
    assert(session.respond(fixed, null, body_included(fixed), fixed.content.length, null));
    assert(line.output[][$ - 9 .. $] == "\r\n\r\nhello" && !session._deferred && !session._out);

    // a body of unknown length is chunked
    line.output.clear();
    Text text = Text("hello");
    HTTPMessage head = create_response(HTTPVersion.V1_1, 200, StringLit!"text/plain", null);
    assert(session.respond(head, &text.produce, true, unknown_length, null));
    assert(line.output[][$ - 15 .. $] == "5\r\nhello\r\n0\r\n\r\n" && !session._deferred && !session._body);

    // HTTP/1.0 is refused a body of unknown length, and the body's owner is told
    static struct End
    {
        bool sent = true;
        void ended(bool s) nothrow @nogc { sent = s; }
    }
    End end;
    line.output.clear();
    text = Text("hello");
    head = create_response(HTTPVersion.V1_0, 200, StringLit!"text/plain", null);
    assert(session.respond(head, &text.produce, true, unknown_length, &end.ended));
    assert(line.output[][0 .. 12] == "HTTP/1.0 505" && !end.sent && !session._body);

    // a response the line cannot take yet holds the parser, and ends with its stream
    end.sent = true;
    line.room = 0;
    text = Text("later");
    head = create_response(HTTPVersion.V1_1, 200, StringLit!"text/plain", null);
    assert(session.respond(head, &text.produce, true, 5, &end.ended));
    assert(session._deferred && session._out);
    session.signal_handler(null, StateSignal.offline);
    assert(!end.sent && session._finished && !session._out && !session._body);
}
