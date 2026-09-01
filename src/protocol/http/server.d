module protocol.http.server;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.mem;
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

version = DebugHTTPServer;

nothrow @nogc:


class HTTPServer : ActiveObject
{
nothrow @nogc:

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

    bool defer_response(Stream stream)
    {
        foreach (session; _sessions)
        {
            if (session.stream is stream)
            {
                session.defer_response();
                return true;
            }
        }
        return false;
    }

    bool resume_response(Stream stream)
    {
        foreach (session; _sessions)
        {
            if (session.stream is stream)
            {
                session.resume_response();
                return true;
            }
        }
        return false;
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
        stream.write(response.format_message()[]);
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
            // registered last: rx_handler immediately flushes any already-buffered bytes
            stream.rx_handler(&on_data);
        }

        void close()
        {
            if (!stream)
                return;
            stream.rx_handler(null);
            unsubscribe_signal(stream);
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
                s.rx_handler(null);
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
            if (_deferred)
                return 0;
            // `stream` may be nulled out by signal_handler or by a request handler
            // that claims the stream, so pin the reference for the final unsubscribe.
            Stream s = stream;
            int result = parser.update(s);
            if (result < 0)
            {
                close();
                return result;
            }
            if (!stream)
            {
                unsubscribe_signal(s);
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
            stream.write(response.format_message()[]);

            return 0;
        }

        HTTPServer server;
        Stream stream;
        RequestHandler redirect_handler;

    private:
        HTTPParser parser;
        bool _subscribed;
        bool _finished;
        bool _deferred;

        void defer_response()
        {
            assert(!_deferred);
            _deferred = true;
            stream.rx_handler(null);
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
                s.rx_handler(null);
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
                unsubscribe_signal(stream);
                stream = null;
            }
        }
    }
}
