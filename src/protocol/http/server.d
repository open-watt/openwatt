module protocol.http.server;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.string.format : tconcat, tstring;
import urt.time;

import manager;
import manager.base;
import manager.certificate : Certificate;
import manager.collection;

import protocol.http;
import protocol.http.message;

import router.stream.tcp;
import router.iface;

version = DebugHTTPServer;

nothrow @nogc:


class HTTPServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("port", port),
                                 Prop!("tls-port", tls_port),
                                 Prop!("certificates", certificates),
                                 Prop!("https-redirect", https_redirect));
nothrow @nogc:

    enum type_name = "http-server";
    enum collection_id = CollectionType.http_server;

    // Handlers may return:
    //   0 = handled, keep the connection open for the next request
    //   1 = handler claimed the stream (e.g. protocol upgrade); `stream` has been set to null.
    //       `leftover` holds any bytes the HTTP parser already read past this request -
    //       the claimer owns them and must process them before the first stream.read().
    //  <0 = error, drop the session
    alias RequestHandler = int delegate(ref const HTTPMessage, ref Stream stream, const(ubyte)[] leftover) nothrow @nogc;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!HTTPServer, id, flags);
    }

    // Properties...

    ushort port() const pure
        => _port;
    const(char)[] port(ushort value)
    {
        if (_port == value)
            return null;
        _port = value;

        if (_server)
            _server.port = _port;
        return null;
    }

    ushort tls_port() const pure
        => _tls_port;
    const(char)[] tls_port(ushort value)
    {
        if (_tls_port == value)
            return null;
        _tls_port = value;

        if (_tls_server)
            _tls_server.port = _tls_port;
        return null;
    }

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
        restart();
    }

    bool https_redirect() const pure
        => _https_redirect;
    void https_redirect(bool value)
    {
        _https_redirect = value;
    }

    // API...

    void set_default_request_handler(RequestHandler default_request_handler)
    {
        _default_request_handler = default_request_handler;
    }

    bool add_uri_handler(HTTPMethod method, const(char)[] uri_prefix, RequestHandler request_handler)
    {
        foreach (ref h; _handlers)
        {
            // if a higher level handler already exists, we can't add this handler
            if ((h.methods & (1 << method)) && uri_prefix[].startsWith(h.uri_prefix[]))
                return false;
        }

        _handlers ~= Handler(1 << method, uri_prefix.makeString(defaultAllocator), request_handler);
        return true;
    }

    void remove_uri_handler(HTTPMethod method, RequestHandler request_handler)
    {
        for (size_t i = 0; i < _handlers.length; )
        {
            if ((_handlers[i].methods & (1 << method)) && _handlers[i].request_handler is request_handler)
            {
                _handlers[i].methods &= ~(1 << method);
                if (_handlers[i].methods == 0)
                    _handlers.remove(i);
                else
                    ++i;
            }
            else
                ++i;
        }
    }

    RequestHandler hook_global_handler(RequestHandler request_handler)
    {
        RequestHandler old = _default_request_handler;
        _default_request_handler = request_handler;
        return old;
    }

    // BaseObject overrides
protected:
//    mixin RekeyHandler;

    override bool validate() const pure
    {
        return _port != 0 || _tls_port != 0;
    }

    override CompletionStatus startup()
    {
        version (DebugHTTPServer)
            log.trace("startup, port=", _port, " tls-port=", _tls_port, " certs=", _certificates.length);

        if (_port != 0 && !_server)
        {
            if (!try_start_http())
                return CompletionStatus.error;
        }

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

        if (_port != 0 || _tls_server)
            return CompletionStatus.complete;
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        version (DebugHTTPServer)
            log.trace("shutdown, sessions=", _sessions.length);

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
            defaultAllocator().freeT(s);
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
                defaultAllocator().freeT(_sessions[i]);
                _sessions.remove(i);
            }
            else
                ++i;
        }
    }

private:
    struct Handler
    {
        uint methods;
        String uri_prefix;
        RequestHandler request_handler;
    }

    ushort _port;
    ushort _tls_port;
    bool _https_redirect;
    bool _cert_subscribed;
    RequestHandler _default_request_handler;

    TCPServer _server;
    TCPServer _tls_server;
    Array!(ObjectRef!Certificate) _certificates;
    Array!Handler _handlers;
    Array!(Session*) _sessions;

    void accept_http_connection(Stream stream, void*)
    {
        log.info("new HTTP session from ", stream.remote_name);
        RequestHandler redirect = (_https_redirect && _tls_port != 0) ? &http_redirect_handler : null;
        _sessions.emplaceBack(defaultAllocator().allocT!Session(this, stream, redirect));
    }

    void accept_tls_connection(Stream stream, void*)
    {
        _sessions.emplaceBack(defaultAllocator().allocT!Session(this, stream, null));
    }

    bool any_cert_valid()
    {
        foreach (ref c; _certificates)
            if (auto cert = cast(Certificate)c.get())
                if (cert.is_valid)
                    return true;
        return false;
    }

    void push_certs_to_tls()
    {
        import protocol.http.tls : TLSServer;
        if (auto tls = cast(TLSServer)_tls_server)
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

    void try_start_tls()
    {
        import protocol.http.tls : TLSServer;
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
            else if (obj is _tls_server)
            {
                log.warning("TLS listener destroyed externally, recreating");
                _tls_server = null;
                try_start_tls();
            }
        }
    }

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
                if (auto cert = cast(Certificate)c.get())
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
        response.headers ~= HTTPParam(StringLit!"Location", location.makeString(defaultAllocator));
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
            parser = HTTPParser(&request_callback);
        }

        void close()
        {
            if (!stream)
                return;
            stream.destroy();
            stream = null;
        }

        int update()
        {
            if (!stream)
                return -1;
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
                if (!_signal_unsubscribed)
                    s.unsubscribe(&signal_handler);
                return -1;
            }
            return 0;
        }

        int request_callback(ref const HTTPMessage request)
        {
            const(ubyte)[] leftover = parser.current_leftover;

            // check redirect interceptor first
            if (redirect_handler)
            {
                int result = redirect_handler(request, stream, leftover);
                if (result != 0)
                    return result;
            }

            foreach (ref h; server._handlers)
            {
                if (((1 << request.method) & h.methods) && request.request_target[].startsWith(h.uri_prefix[]))
                {
                    int result = h.request_handler(request, stream, leftover);
                    if (!stream)
                        return 1; // handler claimed the stream (upgrade)
                    return result;
                }
            }

            if (server._default_request_handler)
            {
                int result = server._default_request_handler(request, stream, leftover);
                if (!stream)
                    return 1;
                return result;
            }

            // implement default response...
            enum message_body = "OpenWatt Webserver";
            HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"text/plain", message_body);
            stream.write(response.format_message()[]);

            return 0;
        }

        HTTPServer server;
        Stream stream;
        RequestHandler redirect_handler;

    private:
        HTTPParser parser;
        bool _signal_unsubscribed;

        void signal_handler(ActiveObject object, StateSignal signal)
        {
            if (signal != StateSignal.online)
            {
                stream.unsubscribe(&signal_handler);
                _signal_unsubscribed = true;
                stream = null;
            }
        }
    }
}
