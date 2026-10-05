module protocol.tls.stream;

version (NoTLS) {}
else
{

// =============================================================================
// TODO: POSIX TLS CLIENT VALIDATION IS DISABLED.
//
// On POSIX (mbedtls), client mode currently uses MBEDTLS_SSL_VERIFY_NONE - we
// accept ANY server certificate without validating the chain, expiry, or
// hostname. TLS gives us encryption-only with zero identity guarantees;
// every outbound connection is trivially MITM-able by anyone on the path.
//
// Windows (Schannel) is fine - SCH_CRED_AUTO_CRED_VALIDATION walks the OS
// trust store and validates chain + hostname. The asymmetry means Windows
// builds get real TLS, Linux/RouterOS/embedded builds get a security smell.
//
// To fix (probably half a day):
//   1. Load a CA bundle on startup
//        - Linux/RouterOS: /etc/ssl/certs/ca-certificates.crt (Alpine, Debian)
//        - Embedded: baked-in bundle, or per-cert pinning
//      via mbedtls_x509_crt_parse_file() / _parse_path()
//   2. mbedtls_ssl_conf_ca_chain(_ssl_conf, &ca_chain, null)
//   3. Flip authmode to MBEDTLS_SSL_VERIFY_REQUIRED
//   4. mbedtls_ssl_set_hostname() is already called - it drives hostname
//      matching once VERIFY_REQUIRED is on, so it Just Works
//   5. Decide policy for self-signed / pinned certs (config-time trust list?)
//
// MUST land before production deployment. The MITM-as-first-class-capability
// direction is fundamentally broken without it: the outbound legs of a router
// MITM must validate cloud cert chains to detect tampering - otherwise our
// MITM defeats its own security model.
// =============================================================================

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.pagepool;
import urt.mem.temp;
import urt.socket;
import urt.string;
import urt.time;

import manager;
import manager.base;
import protocol.tls.certificate : Certificate;
import manager.collection;
import manager.console;
import manager.expression : NamedArgument;
import manager.plugin;

import router.stream;
import protocol.ip.client : IPClient;
import protocol.ip.tcp_stream;
import protocol.ip : TCPConnection;

version (MbedTLS)
{
    import urt.internal.mbedtls;
}
else version (Windows)
{
    import urt.internal.sys.windows;
    import urt.internal.sys.windows.ntsecpkg;
    import urt.internal.sys.windows.schannel;
    import urt.internal.sys.windows.security;
    import urt.internal.sys.windows.sspi;
    import urt.internal.sys.windows.wincrypt;

    pragma(lib, "Secur32");
}

//version = DebugTLS;

nothrow @nogc:


final class TLSStream : Stream
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("remote", remote),
                                 Prop!("keepalive", keepalive),
                                 Prop!("certificate", certificate),
                                 Prop!("certificates", certificates));
nothrow @nogc:

    ~this() {}

    enum type_name = "tls";
    enum path = "/stream/tls";

    this(CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!TLSStream, id, flags, options);
    }

    // Properties...
    inout(Stream) stream() inout pure
        => _stream.get();
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (value is _stream)
            return null;
        release_tx_service();
        if (auto stream = _stream.get)
        {
            stream.release_rx_handler(&inner_rx);
            if (_subscribed)
            {
                stream.unsubscribe(&inner_state_change);
                _subscribed = false;
            }
        }
        if (_conn.get !is null)
            _conn.stop();
        _stream = value;
        mark_set!(typeof(this), "stream")();
        restart();
        return null;
    }

    ref const(String) remote() const pure
        => _conn.host;
    const(char)[] remote(String value)
    {
        if (value.empty)
            return "remote cannot be empty";
        if (value == _conn.host)
            return null;
        auto r = _conn.remote(value.move);
        if (r.failed)
            return r.message;
        mark_set!(typeof(this), "remote")();
        restart();
        return null;
    }

    bool keepalive() const pure
        => _conn.keepalive;
    void keepalive(bool value)
    {
        _conn.keepalive(value);
        mark_set!(typeof(this), "keepalive")();
    }

    void certificate(Certificate value)
    {
        _certificates.clear();
        if (value)
            _certificates.emplaceBack(value);
        mark_set!(typeof(this), "certificates")();
        restart();
    }

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
    void certificates(Certificate[] value...)
    {
        _certificates.clear();
        _certificates.reserve(value.length);
        foreach (c; value)
            _certificates.emplaceBack(c);
        mark_set!(typeof(this), "certificates")();
        restart();
    }

    // API...

    String selected_cert_name() const pure
        => _selected_cert ? _selected_cert.name : String();

    final override ulong tx_link_speed() const
        => _stream ? _stream.tx_link_speed : 0;
    final override ulong rx_link_speed() const
        => _stream ? _stream.rx_link_speed : 0;

    final override bool validate() const pure
    {
        // Server mode: need a certificate. Client mode: need a remote host.
        if (_certificates.length > 0)
            return true;
        return _conn.has_remote();
    }

    final override CompletionStatus startup()
    {
        bool is_server = _certificates.length > 0;

        version (DebugTLS)
            log.trace("startup, server=", is_server, " stream=", _stream !is null);

        if (!_stream)
        {
            if (is_server)
            {
                // Server-mode: stream must be pre-assigned (by TLSServer.create_stream).
                // If it's null here, something went wrong.
                log.error("no underlying stream for server connection");
                return CompletionStatus.error;
            }

            // Client-mode: bring up an owned TCP stream to connect outward.
            if (!_conn.start(this))
            {
                log.error("failed to create underlying TCP stream");
                return CompletionStatus.error;
            }
            _stream = _conn.get;
        }
        if (!_stream.running)
        {
            // Server-mode: the TCP stream was created already running.
            // If it's no longer running, the peer disconnected.
            if (is_server && _handshake_start != SysTime())
                return CompletionStatus.error;
            return CompletionStatus.continue_;
        }

        if (_stream.rx_handler !is &inner_rx)
            _stream.rx_handler(&inner_rx);

        // Start handshake timeout when the stream first becomes available.
        if (_handshake_start == SysTime())
            _handshake_start = getSysTime();

        if (_handshake_state == HandshakeState.not_started)
        {
            if (is_server)
            {
                // Wait for the full ClientHello record, for SNI
                if (_receive_buffer.length < 5)
                    return CompletionStatus.continue_;
                ushort rec_len = (_receive_buffer[3] << 8) | _receive_buffer[4];
                if (_receive_buffer.length < 5 + rec_len)
                    return CompletionStatus.continue_;

                // Select certificate via SNI (or fallback)
                BaseObject selected = select_certificate();
                if (!selected)
                {
                    version (DebugTLS)
                    {
                        const(char)[] sni = extract_sni_hostname(_receive_buffer[]);
                        log.trace("no valid certificate available yet (sni='", sni, "' certs=", _certificates.length, ")");
                        foreach (ref c; _certificates)
                        {
                            if (auto cert = dyn_cast!Certificate(c.get()))
                                log.trace("  cert '", cert.name, "': valid=", cert.is_valid, " domain='", cert.domain, "'");
                            else
                                log.trace("  cert: null ref");
                        }
                    }
                    return CompletionStatus.continue_;
                }

                version (DebugTLS)
                    log.trace("selected cert '", selected.name, "'");
                _selected_cert = selected;
            }

            version (MbedTLS)
            {
                if (is_server)
                    init_mbedtls_context(true, dyn_cast!Certificate(_selected_cert));
                else
                    init_mbedtls_context(false, null);
            }
            else version (Windows)
            {
                if (is_server)
                {
                    init_context(true, cast(const(CERT_CONTEXT)*)dyn_cast!Certificate(_selected_cert).get_cert_context());
                    // process the already-buffered ClientHello
                    if (_handshake_state == HandshakeState.in_progress)
                        advance_handshake(_conn.host[], true);
                }
                else
                    init_context(false, null);
            }
        }

        if (_handshake_state == HandshakeState.in_progress)
        {
            version (MbedTLS)
            {
                int ret = mbedtls_ssl_handshake(_ssl);
                if (ret == 0)
                    _handshake_state = HandshakeState.completed;
                else if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE)
                {
                    version (DebugTLS)
                        log.trace("TLS handshake failed: -", cast(uint)(-ret));
                    _handshake_state = HandshakeState.failed;
                }
            }
            else version (Windows)
            {
                if (_receive_buffer.length)
                    advance_handshake(_conn.host[], is_server);
            }
        }

        if (_handshake_state == HandshakeState.completed)
        {
            // an owned connection restarts us through IPClient; a stream handed to us is watched here
            if (!_conn.has_remote())
            {
                _stream.subscribe(&inner_state_change);
                _subscribed = true;
            }
            tx_handler_changed();
            rx_handler_changed();
            if (_selected_cert)
                log.info("HTTPS session on ", _stream.name, " cert='", _selected_cert.name, "'");
            else
                log.info("connected on ", _stream.name);
            return CompletionStatus.complete;
        }
        if (_handshake_state == HandshakeState.failed)
        {
            log.warning("handshake failed");
            return CompletionStatus.error;
        }

        // Server-mode: timeout stalled handshakes (abandoned connections).
        if (is_server && getSysTime() - _handshake_start > seconds(15))
        {
            log.warning("handshake timeout");
            return CompletionStatus.error;
        }
        return CompletionStatus.continue_;
    }

    final override CompletionStatus shutdown()
    {
        g_app.cancel(&resume_rx);
        release_tx_service();
        if (auto stream = _stream.get)
        {
            stream.release_rx_handler(&inner_rx);
            if (_subscribed)
                stream.unsubscribe(&inner_state_change);
        }
        _subscribed = false;
        free_pending_tx();
        version (MbedTLS)
        {
            free_mbedtls_contexts();
        }
        else version (Windows)
        {
            if (_context.dwLower != 0 || _context.dwUpper != 0)
                DeleteSecurityContext(&_context);
            if (_credentials.dwLower != 0 || _credentials.dwUpper != 0)
                FreeCredentialsHandle(&_credentials);
        }

        _receive_buffer.clear();
        _close_notify = false;
        _selected_cert = null;
        _handshake_start = SysTime();

        if (_conn.has_remote())
            _conn.stop();
        else if (_stream)
            _stream.destroy();
        _stream = null;

        _handshake_state = HandshakeState.not_started;

        return CompletionStatus.complete;
    }

    final override ptrdiff_t write(const(void[])[] data...)
    {
        if (_handshake_state != HandshakeState.completed)
        {
            version (DebugTLS)
                log.trace("write rejected, handshake state=", _handshake_state);
            return -1;
        }

        bool idle = !_tx_pending;
        ptrdiff_t total = 0;
        queue: foreach (ref d; data)
        {
            const(ubyte)[] chunk = cast(const(ubyte)[])d;
            while (chunk.length)
            {
                size_t n = chunk.length < tx_page_payload ? chunk.length : tx_page_payload;
                Page* input = page_alloc(n);
                if (!input)
                    break queue;
                (cast(ubyte[])input.data)[] = chunk[0 .. n];
                Page* output = encrypt_page(input);
                if (!output)
                {
                    fail_session();
                    return -1;
                }
                append_tx_chain(_tx_pending, output);
                add_tx_bytes(n);
                if (_logging)
                    write_to_log(false, chunk[0 .. n]);
                chunk = chunk[n .. $];
                total += n;
            }
        }
        if (idle && _tx_pending)
            tx_handler_changed();
        return total;
    }

    final override size_t tx_request() const
    {
        if (_handshake_state != HandshakeState.completed)
            return 0;
        if (auto stream = _stream.get)
            return stream.tx_request;
        return 0;
    }

protected:

    // a consumer that returns is served on the next pass, and the transport reads again after it
    final override void rx_handler_changed()
    {
        if (!rx_handler || _handshake_state != HandshakeState.completed || _close_notify)
            return;
        g_app.cancel(&resume_rx);
        g_app.schedule(getTime(), &resume_rx);
    }

    final override void tx_handler_changed()
    {
        Stream stream = _stream.get;
        if (!stream)
            return;
        if ((tx_handler || _tx_pending) && running && _handshake_state == HandshakeState.completed)
            stream.tx_handler(&provide_tx_page);
        else
            stream.release_tx_handler(&provide_tx_page);
    }

private:
    IPClient _conn;
    bool _close_notify = false;
    bool _decrypting;
    bool _subscribed;
    TxStatus _tx_pending_status;

    Array!(ObjectRef!Certificate) _certificates;
    BaseObject _selected_cert;
    ObjectRef!Stream _stream;
    Array!ubyte _receive_buffer;
    Page* _tx_pending;
    SysTime _handshake_start;

    void release_tx_service()
    {
        if (auto stream = _stream.get)
            stream.release_tx_handler(&provide_tx_page);
    }

    Page* provide_tx_page(ref const TxRequest req, out TxStatus status)
    {
        if (_tx_pending)
            return take_pending_tx(req, status);

        Page* input = request_tx_page(req, status);
        if (!input)
            return null;

        size_t input_length = input.length;
        if (_logging)
            write_to_log(false, input.data);

        Page* output = encrypt_page(input);
        if (!output)
        {
            fail_session();
            status = TxStatus.abort;
            return null;
        }
        add_tx_bytes(input_length);
        _tx_pending = output;
        _tx_pending_status = status;
        return take_pending_tx(req, status);
    }

    Page* take_pending_tx(ref const TxRequest req, out TxStatus status)
    {
        Page* page = take_tx_page(_tx_pending, req, status);
        if (page)
            status = _tx_pending || tx_handler ? TxStatus.more : _tx_pending_status;
        return page;
    }

    // consumes input
    Page* encrypt_page(Page* input)
    {
        version (MbedTLS)
            return encrypt_page_mbedtls(input);
        else version (Windows)
            return encrypt_page_schannel(input);
        else
        {
            page_free(input);
            return null;
        }
    }

    // a record may have advanced the cipher state before its ciphertext was lost, so the session cannot continue
    void fail_session()
    {
        free_pending_tx();
        tx_handler(null);
        _handshake_state = HandshakeState.failed;
        restart();
    }

    void free_pending_tx()
    {
        free_page_chain(_tx_pending);
        _tx_pending = null;
    }

    static void free_page_chain(Page* page)
    {
        while (page)
        {
            Page* next = page.next;
            page_free(page);
            page = next;
        }
    }

    void inner_state_change(ActiveObject, StateSignal signal)
    {
        if (signal != StateSignal.offline)
            return;
        // a temporary stream destroys itself as it goes offline, so it is let go rather than destroyed again
        Stream stream = _stream.get;
        if (stream && (stream.flags & ObjectFlags.temporary))
        {
            stream.release_rx_handler(&inner_rx);
            stream.unsubscribe(&inner_state_change);
            _subscribed = false;
            _stream = null;
        }
        restart();
    }

    // once established, ciphertext is read only while there is a consumer for the plaintext
    void inner_rx(Stream stream, const(void)[] data, MonoTime rx_time)
    {
        _receive_buffer ~= cast(const(ubyte)[])data;
        if (_handshake_state != HandshakeState.completed || _close_notify)
            return;
        if (rx_handler)
            decrypt_received(rx_time);
        if (!rx_handler)
            stream.release_rx_handler(&inner_rx);
    }

    void resume_rx(MonoTime now)
    {
        Stream stream = _stream.get;
        if (!stream || !rx_handler || _handshake_state != HandshakeState.completed || _close_notify)
            return;
        decrypt_received(now);
        if (rx_handler && _handshake_state == HandshakeState.completed && !_close_notify && stream.rx_handler !is &inner_rx)
            stream.rx_handler(&inner_rx);
    }

    // ciphertext waits in the receive buffer until this stream has a consumer for the plaintext
    void decrypt_received(MonoTime rx_time)
    {
        // a consumer that re-arms from inside its delivery is served by the loop already running
        if (_decrypting)
            return;
        _decrypting = true;
        scope (exit)
        {
            _decrypting = false;
            if (_close_notify || _handshake_state == HandshakeState.failed)
                restart_deferred();
        }

        version (MbedTLS)
        {
            ubyte[8192] read_buf = void;
            while (rx_handler)
            {
                int ret = mbedtls_ssl_read(_ssl, read_buf.ptr, read_buf.length);
                if (ret > 0)
                {
                    incoming(read_buf[0 .. ret], rx_time);
                    if (_handshake_state != HandshakeState.completed)
                        return;   // the consumer ended the session
                }
                else if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
                {
                    version (DebugTLS)
                        log.trace("close_notify received");
                    _close_notify = true;
                    return;
                }
                else if (ret == MBEDTLS_ERR_SSL_WANT_READ)
                    return;
                else
                {
                    version (DebugTLS)
                        log.trace("TLS read error: -", cast(uint)(-ret));
                    _handshake_state = HandshakeState.failed;
                    return;
                }
            }
        }
        else version (Windows)
        {
            while (rx_handler && _receive_buffer.length > 0)
            {
                SecBuffer[4] bufs;
                bufs[0].pvBuffer = &_receive_buffer[0];
                bufs[0].cbBuffer = cast(ULONG)_receive_buffer.length;
                bufs[0].BufferType = SECBUFFER_DATA;
                bufs[1].BufferType = SECBUFFER_EMPTY;
                bufs[2].BufferType = SECBUFFER_EMPTY;
                bufs[3].BufferType = SECBUFFER_EMPTY;

                SecBufferDesc buf_desc;
                buf_desc.ulVersion = 0;
                buf_desc.cBuffers = 4;
                buf_desc.pBuffers = bufs.ptr;

                auto status = DecryptMessage(&_context, &buf_desc, 0, null);

                if (status == SEC_I_RENEGOTIATE)
                {
                    // TODO: Handle renegotiation by resetting state
                    log.warning("renegotiation requested (not supported)");
                    _handshake_state = HandshakeState.failed;
                    return;
                }
                else if (status == SEC_I_CONTEXT_EXPIRED)
                {
                    version (DebugTLS)
                        log.trace("close_notify received");
                    _receive_buffer.clear();
                    _close_notify = true;
                    return;
                }
                else if (status == SEC_E_INCOMPLETE_MESSAGE)
                {
                    // Not enough data to form a full TLS record, wait for more.
                    return;
                }

                if (status != SEC_E_OK)
                {
                    log.warningf("decryption failed, status={0,08x}", cast(uint)status);
                    _handshake_state = HandshakeState.failed;
                    _receive_buffer.clear();
                    return;
                }

                SecBuffer* data_buf = null;
                SecBuffer* extra_buf = null;
                foreach (ref buf; bufs)
                {
                    if (buf.BufferType == SECBUFFER_DATA && !data_buf)
                        data_buf = &buf;
                    else if (buf.BufferType == SECBUFFER_EXTRA && !extra_buf)
                        extra_buf = &buf;
                }
                size_t extra = extra_buf ? extra_buf.cbBuffer : 0;

                if (data_buf)
                {
                    incoming((cast(ubyte*)data_buf.pvBuffer)[0 .. data_buf.cbBuffer], rx_time);
                    if (_handshake_state != HandshakeState.completed)
                        return;   // the consumer ended the session
                }

                if (extra)
                    _receive_buffer.remove(0, _receive_buffer.length - extra);
                else
                    _receive_buffer.clear();
            }
        }
    }

    Certificate select_certificate()
    {
        const(char)[] sni = extract_sni_hostname(_receive_buffer[]);

        if (sni.length > 0)
        {
            // Exact domain match
            foreach (ref c; _certificates)
            {
                if (auto cert = dyn_cast!Certificate(c.get()))
                    if (cert.is_valid && cert.domain[] == sni)
                        return c.get();
            }
        }

        // Fallback: first cert with no domain (self-signed)
        foreach (ref c; _certificates)
        {
            if (auto cert = dyn_cast!Certificate(c.get()))
                if (cert.is_valid && cert.domain[].empty)
                    return c.get();
        }

        // Last resort: first valid cert
        foreach (ref c; _certificates)
        {
            if (auto cert = dyn_cast!Certificate(c.get()))
                if (cert.is_valid)
                    return c.get();
        }

        return null;
    }

    enum HandshakeState
    {
        not_started,
        in_progress,
        completed,
        failed,
    }
    HandshakeState _handshake_state;

    enum size_t tx_page_payload = 1600;

    version (MbedTLS)
    {
        mbedtls_ssl_context* _ssl;
        mbedtls_ssl_config* _ssl_conf;
        Page* _tx_output_head;
        Page* _tx_output_tail;
        size_t _tx_output_page_limit;
        size_t _tx_output_headroom;
        size_t _tx_output_tailroom;
        bool _capturing_tx;
        bool _tx_output_failed;

        Page* encrypt_page_mbedtls(Page* input)
        {
            _tx_output_headroom = input.headroom;
            _tx_output_tailroom = input.tailroom;
            _capturing_tx = true;
            _tx_output_failed = false;
            const(ubyte)[] remaining = cast(const(ubyte)[])input.data;
            while (remaining.length)
            {
                int written = mbedtls_ssl_write(_ssl, remaining.ptr, remaining.length);
                if (written <= 0)
                {
                    free_page_chain(_tx_output_head);
                    clear_tx_output();
                    page_free(input);
                    return null;
                }
                remaining = remaining[written .. $];
            }
            Page* output = _tx_output_head;
            if (_tx_output_failed || !output)
            {
                free_page_chain(output);
                output = null;
            }
            clear_tx_output();
            page_free(input);
            return output;
        }

        void clear_tx_output()
        {
            _tx_output_head = null;
            _tx_output_tail = null;
            _tx_output_page_limit = 0;
            _tx_output_headroom = 0;
            _tx_output_tailroom = 0;
            _capturing_tx = false;
            _tx_output_failed = false;
        }

        void init_mbedtls_context(bool is_server, Certificate cert)
        {
            // Ensure the global RNG is initialised (no-op after the first call).
            // On 4.x this brings up PSA; on <4 it seeds the module-static CTR-DRBG.
            int ret = urt_rng_init();
            if (ret != 0)
            {
                free_mbedtls_contexts();
                _handshake_state = HandshakeState.failed;
                return;
            }

            _ssl_conf = urt_ssl_config_new();
            if (_ssl_conf is null)
            {
                free_mbedtls_contexts();
                _handshake_state = HandshakeState.failed;
                return;
            }

            ret = mbedtls_ssl_config_defaults(_ssl_conf,
                is_server ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
                MBEDTLS_SSL_TRANSPORT_STREAM,
                MBEDTLS_SSL_PRESET_DEFAULT);
            if (ret != 0)
            {
                free_mbedtls_contexts();
                _handshake_state = HandshakeState.failed;
                return;
            }

            urt_ssl_attach_rng(_ssl_conf);

            if (is_server && cert !is null)
            {
                auto x509 = cast(mbedtls_x509_crt*)cert.get_cert_context();
                auto pk = cast(mbedtls_pk_context*)cert.get_key_context();
                if (x509 is null || pk is null)
                {
                    log.error("certificate missing cert or key context");
                    free_mbedtls_contexts();
                    _handshake_state = HandshakeState.failed;
                    return;
                }
                ret = mbedtls_ssl_conf_own_cert(_ssl_conf, x509, pk);
                if (ret != 0)
                {
                    version (DebugTLS)
                        log.trace("ssl_conf_own_cert failed: -", cast(uint)(-ret));
                    free_mbedtls_contexts();
                    _handshake_state = HandshakeState.failed;
                    return;
                }
                mbedtls_ssl_conf_authmode(_ssl_conf, MBEDTLS_SSL_VERIFY_NONE);
            }
            else if (!is_server)
            {
                // Client mode: skip server cert verification for now
                mbedtls_ssl_conf_authmode(_ssl_conf, MBEDTLS_SSL_VERIFY_NONE);
            }

            _ssl = urt_ssl_new();
            if (_ssl is null)
            {
                free_mbedtls_contexts();
                _handshake_state = HandshakeState.failed;
                return;
            }

            ret = mbedtls_ssl_setup(_ssl, _ssl_conf);
            if (ret != 0)
            {
                free_mbedtls_contexts();
                _handshake_state = HandshakeState.failed;
                return;
            }

            mbedtls_ssl_set_bio(_ssl, cast(void*)this, &tls_bio_send, &tls_bio_recv, null);

            if (!is_server && !_conn.host.empty)
            {
                auto host = _conn.host[];
                auto colon = host.findFirst(':');
                if (colon < host.length)
                    host = host[0 .. colon];
                mbedtls_ssl_set_hostname(_ssl, host.tstringz);
            }

            _handshake_state = HandshakeState.in_progress;
        }

        void free_mbedtls_contexts()
        {
            if (_ssl !is null)
            {
                mbedtls_ssl_close_notify(_ssl);
                urt_ssl_delete(_ssl);
                _ssl = null;
            }
            if (_ssl_conf !is null)
            {
                urt_ssl_config_delete(_ssl_conf);
                _ssl_conf = null;
            }
        }
    }
    else version (Windows)
    {
        CredHandle _credentials;
        CtxtHandle _context;

        Page* encrypt_page_schannel(Page* input)
        {
            SecPkgContext_StreamSizes sizes;
            auto status = QueryContextAttributesA(&_context, SECPKG_ATTR_STREAM_SIZES, &sizes);
            if (status != SEC_E_OK || sizes.cbMaximumMessage == 0)
            {
                page_free(input);
                return null;
            }

            size_t input_length = input.length;
            if (input_length <= sizes.cbMaximumMessage && input.headroom >= sizes.cbHeader && input.tailroom >= sizes.cbTrailer)
            {
                input.offset -= cast(ushort)sizes.cbHeader;
                input.length += cast(ushort)(sizes.cbHeader + sizes.cbTrailer);
                if (!encrypt_schannel_record(input, input_length, sizes))
                {
                    page_free(input);
                    return null;
                }
                return input;
            }

            const(ubyte)[] plaintext = cast(const(ubyte)[])input.data;
            size_t position;
            Page* head;
            Page* tail;
            while (position != input_length)
            {
                size_t length = input_length - position;
                if (length > sizes.cbMaximumMessage)
                    length = sizes.cbMaximumMessage;
                size_t output_length = sizes.cbHeader + length + sizes.cbTrailer;
                Page* output = page_alloc(output_length, size_t.sizeof, input.headroom, input.tailroom);
                if (!output)
                {
                    free_page_chain(head);
                    page_free(input);
                    return null;
                }
                (cast(ubyte[])output.data)[sizes.cbHeader .. sizes.cbHeader + length] = plaintext[position .. position + length];
                if (!encrypt_schannel_record(output, length, sizes))
                {
                    page_free(output);
                    free_page_chain(head);
                    page_free(input);
                    return null;
                }
                if (tail)
                    tail.next = output;
                else
                    head = output;
                tail = output;
                position += length;
            }
            page_free(input);
            return head;
        }

        bool encrypt_schannel_record(Page* output, size_t input_length,
                                     ref const SecPkgContext_StreamSizes sizes)
        {
            ubyte[] encrypted = cast(ubyte[])output.data;
            SecBuffer[4] buffers;
            buffers[0].pvBuffer = encrypted.ptr;
            buffers[0].cbBuffer = sizes.cbHeader;
            buffers[0].BufferType = SECBUFFER_STREAM_HEADER;
            buffers[1].pvBuffer = encrypted.ptr + sizes.cbHeader;
            buffers[1].cbBuffer = cast(ULONG)input_length;
            buffers[1].BufferType = SECBUFFER_DATA;
            buffers[2].pvBuffer = encrypted.ptr + sizes.cbHeader + input_length;
            buffers[2].cbBuffer = sizes.cbTrailer;
            buffers[2].BufferType = SECBUFFER_STREAM_TRAILER;
            buffers[3].BufferType = SECBUFFER_EMPTY;

            SecBufferDesc descriptor;
            descriptor.ulVersion = SECBUFFER_VERSION;
            descriptor.cBuffers = buffers.length;
            descriptor.pBuffers = buffers.ptr;
            auto status = EncryptMessage(&_context, 0, &descriptor, 0);
            if (status != SEC_E_OK)
                return false;

            size_t data_offset = buffers[0].cbBuffer;
            memmove(encrypted.ptr + data_offset, buffers[1].pvBuffer, buffers[1].cbBuffer);
            size_t trailer_offset = data_offset + buffers[1].cbBuffer;
            memmove(encrypted.ptr + trailer_offset, buffers[2].pvBuffer, buffers[2].cbBuffer);
            output.length = cast(ushort)(trailer_offset + buffers[2].cbBuffer);
            return true;
        }

        void init_context(bool is_server, const(CERT_CONTEXT)* pCertContext)
        {
            SCHANNEL_CRED creds = void;
            ZeroMemory(&creds, SCHANNEL_CRED.sizeof);
            creds.dwVersion = SCHANNEL_CRED_VERSION;
            creds.grbitEnabledProtocols = 0;
            if (is_server)
            {
                creds.cCreds = 1;
                creds.paCred = cast(const(CERT_CONTEXT)**)&pCertContext;
                creds.dwFlags |= SCH_CRED_NO_DEFAULT_CREDS;
            }
            else
            {
                creds.dwFlags = SCH_CRED_AUTO_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS;
            }

            auto status = AcquireCredentialsHandleA(null, cast(char*)UNISP_NAME_A.ptr, is_server ? SECPKG_CRED_INBOUND : SECPKG_CRED_OUTBOUND, null, &creds, null, null, &_credentials, null);
            if (status != SEC_E_OK)
            {
                log.errorf("AcquireCredentialsHandleA failed: {0,08x}", cast(uint)status);
                _handshake_state = HandshakeState.failed;
                return;
            }

            _handshake_state = HandshakeState.in_progress;

            // For a client, we kick off the handshake immediately.
            if (!is_server)
                advance_handshake(_conn.host[], false);
        }

        void advance_handshake(const(char)[] host, bool is_server)
        {
            size_t consumed = 0;
            do
            {
                ubyte[] data = _receive_buffer[consumed .. $];
                if (data.ptr)
                {
                    if (data.length < 5)
                        break;
                    ushort record_len = (data[3] << 8) | data[4]; // HACK: TLS HEADER has 16 bit LEN FIELD HERE
                    if (data.length < 5 + record_len)
                        break;
                    data = data[0 .. 5 + record_len];
                }

                SECURITY_STATUS status;
                DWORD sspi_flags = is_server
                    ? ASC_REQ_SEQUENCE_DETECT | ASC_REQ_REPLAY_DETECT | ASC_REQ_CONFIDENTIALITY | ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM
                    : ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
                SecBufferDesc out_buf_desc;
                SecBuffer out_buf;
                SecBufferDesc in_buf_desc;
                SecBuffer[2] in_buf;
                DWORD sspi_out_flags;

                // Setup output buffer
                out_buf_desc.ulVersion = SECBUFFER_VERSION;
                out_buf_desc.cBuffers = 1;
                out_buf_desc.pBuffers = &out_buf;
                out_buf.cbBuffer = 0;
                out_buf.BufferType = SECBUFFER_TOKEN;
                out_buf.pvBuffer = null;

                // Setup input buffer
                in_buf_desc.ulVersion = SECBUFFER_VERSION;
                in_buf_desc.cBuffers = 2;
                in_buf_desc.pBuffers = in_buf.ptr;
                in_buf[0].pvBuffer = data.length ? cast(void*)data.ptr : null;
                in_buf[0].cbBuffer = cast(ULONG)data.length;
                in_buf[0].BufferType = SECBUFFER_TOKEN;
                in_buf[1].pvBuffer = null;
                in_buf[1].cbBuffer = 0;
                in_buf[1].BufferType = SECBUFFER_EMPTY;

                if (is_server)
                    status = AcceptSecurityContext(&_credentials, _context.dwLower == 0 && _context.dwUpper == 0 ? null : &_context, &in_buf_desc, sspi_flags, 0, &_context, &out_buf_desc, &sspi_out_flags, null);
                else
                {
                    host = host[0 .. host.findFirst(':')];
                    status = InitializeSecurityContextA(&_credentials, _context.dwLower == 0 && _context.dwUpper == 0 ? null : &_context, host.tstringz, sspi_flags, 0, 0, data.length ? &in_buf_desc : null, 0, &_context, &out_buf_desc, &sspi_out_flags, null);
                }

                // If there's an output token, send it.
                if (out_buf.cbBuffer != 0 && out_buf.pvBuffer !is null)
                {
                    ptrdiff_t bytes_sent = _stream.write(out_buf.pvBuffer[0 .. out_buf.cbBuffer]);
                    FreeContextBuffer(out_buf.pvBuffer);
                    if (bytes_sent != out_buf.cbBuffer)
                    {
                        log.error("failed to send handshake token");
                        _handshake_state = HandshakeState.failed;
                        break; // Exit loop on error
                    }
                }

                if (status == SEC_E_OK)
                {
                    _handshake_state = HandshakeState.completed;
                    consumed += data.length;
                }
                else if (status == SEC_I_CONTINUE_NEEDED)
                {
                    _handshake_state = HandshakeState.in_progress;
                    consumed += data.length;
                }
                else if (status == SEC_E_INCOMPLETE_MESSAGE)
                    break; // Need more data, break the loop and wait for the next poll.
                else if (status == SEC_I_RENEGOTIATE)
                {
                    log.warning("renegotiation requested (not supported)");
                    _handshake_state = HandshakeState.failed;
                    break;
                }
                else
                {
                    log.warningf("handshake failed: {0,08x}", cast(uint)status);
                    _handshake_state = HandshakeState.failed;
                    break;
                }
            }
            while (consumed < _receive_buffer.length);

            // After the loop, perform one single, efficient trim of the buffer.
            if (consumed > 0)
                _receive_buffer.remove(0, consumed);
        }
    }
}

final class TLSServer : TCPServer
{
    alias Properties = AliasSeq!(Prop!("certificate", certificate),
                                 Prop!("certificates", certificates));
nothrow @nogc:

    ~this() {}
    enum type_name = "tls-server";
    enum path = "/protocol/tls/server";
    enum collection_id = CollectionType.tls_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TLSServer, id, flags);
    }

    void certificate(Certificate value)
    {
        _certificates.clear();
        if (value)
            _certificates.emplaceBack(value);
        mark_set!(typeof(this), "certificates")();
        restart();
    }

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
    void certificates(Certificate[] value...)
    {
        _certificates.clear();
        _certificates.reserve(value.length);
        foreach (c; value)
            _certificates.emplaceBack(c);
        mark_set!(typeof(this), "certificates")();
        restart();
    }

    void set_certificate_array(ObjectRef!Certificate[] certs)
    {
        _certificates.clear();
        _certificates.reserve(certs.length);
        foreach (ref c; certs)
            if (c)
                _certificates.emplaceBack(c.get());
    }

protected:

    final override bool validate() const pure
        => super.validate() && _certificates.length > 0;

    final override CompletionStatus startup()
    {
        foreach (ref cert; _certificates[])
            if (cert && cert.running)
                return super.startup();
        return CompletionStatus.continue_;
    }

    final override Stream create_stream(TCPConnection* conn)
    {
        version (DebugTLS)
            log.trace("creating TLS stream for connection from ", conn.remote());

        BaseObject[32] certs;
        size_t num_certs = 0;
        foreach (ref cert; _certificates[])
            if (auto c = cert.get())
                certs[num_certs++] = c;
        if (num_certs == 0)
        {
            log.error("no valid certificates for new connection");
            return null;
        }

        Stream tcp = super.create_stream(conn);
        const(char)[] stream_name = Collection!TLSStream().generate_name(tconcat(name[], "_conn"));
        auto tls = Collection!TLSStream().create(stream_name[], cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
            NamedArgument("stream", tcp), NamedArgument("certificates", certs[0 .. num_certs]));
        if (!tls)
        {
            log.error("failed to create TLS stream '", stream_name, "'");
            tcp.destroy();
            return null;
        }

        version (DebugTLS)
            log.trace("TLS stream created: ", stream_name);

        return tls;
    }

private:

    Array!(ObjectRef!Certificate) _certificates;
}



private:

// extract SNI hostname from a raw TLS ClientHello record
const(char)[] extract_sni_hostname(const(ubyte)[] data) nothrow @nogc
{
    // Minimum: 5 (record hdr) + 4 (handshake hdr) + 2 (version) + 32 (random) = 43
    if (data.length < 43)
        return null;

    // TLS record header: type=0x16 (handshake)
    if (data[0] != 0x16)
        return null;

    size_t pos = 5; // skip record header

    // Handshake header: type=0x01 (ClientHello), 3-byte length
    if (data[pos] != 0x01)
        return null;
    pos += 4; // skip handshake header

    // ClientHello: version (2) + random (32)
    pos += 34;
    if (pos >= data.length)
        return null;

    // Session ID: 1-byte length + variable
    ubyte session_id_len = data[pos];
    pos += 1 + session_id_len;
    if (pos + 2 > data.length)
        return null;

    // Cipher suites: 2-byte length + variable
    ushort cipher_suites_len = (data[pos] << 8) | data[pos + 1];
    pos += 2 + cipher_suites_len;
    if (pos + 1 > data.length)
        return null;

    // Compression methods: 1-byte length + variable
    ubyte compression_len = data[pos];
    pos += 1 + compression_len;
    if (pos + 2 > data.length)
        return null;

    // Extensions: 2-byte total length
    ushort extensions_len = (data[pos] << 8) | data[pos + 1];
    pos += 2;
    size_t extensions_end = pos + extensions_len;
    if (extensions_end > data.length)
        return null;

    // Walk extensions looking for SNI (type 0x0000)
    while (pos + 4 <= extensions_end)
    {
        ushort ext_type = (data[pos] << 8) | data[pos + 1];
        ushort ext_len = (data[pos + 2] << 8) | data[pos + 3];
        pos += 4;

        if (pos + ext_len > extensions_end)
            return null;

        if (ext_type == 0x0000) // server_name
        {
            // SNI extension data: list_len(2), [name_type(1), name_len(2), name...]
            if (ext_len < 5)
                return null;
            // ushort list_len = (data[pos] << 8) | data[pos + 1];
            ubyte name_type = data[pos + 2];
            ushort name_len = (data[pos + 3] << 8) | data[pos + 4];

            if (name_type != 0x00) // host_name
                return null;
            if (pos + 5 + name_len > extensions_end)
                return null;

            return cast(const(char)[])data[pos + 5 .. pos + 5 + name_len];
        }

        pos += ext_len;
    }

    return null;
}

version (MbedTLS)
{
    // BIO callbacks for mbedtls; called during ssl_handshake, ssl_read, ssl_write
    // p_bio is the TLSStream instance (set via mbedtls_ssl_set_bio)

    extern(C) int tls_bio_recv(void* ctx, ubyte* buf, size_t len) nothrow @nogc
    {
        auto self = cast(TLSStream)ctx;

        if (self._receive_buffer.length > 0)
        {
            size_t n = len < self._receive_buffer.length ? len : self._receive_buffer.length;
            buf[0 .. n] = self._receive_buffer[0 .. n];
            self._receive_buffer.remove(0, n);
            return cast(int)n;
        }

        return MBEDTLS_ERR_SSL_WANT_READ;
    }

    extern(C) int tls_bio_send(void* ctx, const(ubyte)* buf, size_t len) nothrow @nogc
    {
        auto self = cast(TLSStream)ctx;
        if (self._capturing_tx)
        {
            size_t consumed;
            while (consumed != len)
            {
                if (!self._tx_output_tail || self._tx_output_tail.length == self._tx_output_page_limit)
                {
                    size_t capacity = len - consumed;
                    if (capacity > TLSStream.tx_page_payload)
                        capacity = TLSStream.tx_page_payload;
                    Page* page = page_alloc(0, size_t.sizeof, self._tx_output_headroom, capacity + self._tx_output_tailroom);
                    if (!page)
                    {
                        self._tx_output_failed = true;
                        return -1;
                    }
                    if (self._tx_output_tail)
                        self._tx_output_tail.next = page;
                    else
                        self._tx_output_head = page;
                    self._tx_output_tail = page;
                    self._tx_output_page_limit = capacity;
                }

                size_t copied = self._tx_output_page_limit - self._tx_output_tail.length;
                if (copied > len - consumed)
                    copied = len - consumed;
                size_t offset = self._tx_output_tail.length;
                self._tx_output_tail.length += cast(ushort)copied;
                (cast(ubyte[])self._tx_output_tail.data)[offset .. offset + copied] = buf[consumed .. consumed + copied];
                consumed += copied;
            }
            return cast(int)len;
        }
        ptrdiff_t n = self._stream.write(buf[0 .. len]);
        if (n > 0)
            return cast(int)n;
        if (n == 0)
            return MBEDTLS_ERR_SSL_WANT_WRITE;
        return -1;
    }

}

version (Windows)
{
    extern(Windows)
    {
        SECURITY_STATUS FreeCredentialsHandle(PCredHandle);
        SECURITY_STATUS AcquireCredentialsHandleA(SEC_CHAR*,SEC_CHAR*,ULONG,PLUID,PVOID,SEC_GET_KEY_FN,PVOID,PCredHandle,PTimeStamp);
        SECURITY_STATUS AcceptSecurityContext(PCredHandle,PCtxtHandle,PSecBufferDesc,ULONG,ULONG,PCtxtHandle,PSecBufferDesc,PULONG,PTimeStamp);
        SECURITY_STATUS InitializeSecurityContextA(PCredHandle,PCtxtHandle,SEC_CHAR*,ULONG,ULONG,ULONG,PSecBufferDesc,ULONG,PCtxtHandle,PSecBufferDesc,PULONG,PTimeStamp);
        SECURITY_STATUS FreeContextBuffer(PVOID);
        SECURITY_STATUS QueryContextAttributesA(PCtxtHandle,ULONG,PVOID);
        SECURITY_STATUS DecryptMessage(PCtxtHandle,PSecBufferDesc,ULONG,PULONG);
        SECURITY_STATUS EncryptMessage(PCtxtHandle,ULONG,PSecBufferDesc,ULONG);
        SECURITY_STATUS DeleteSecurityContext(PCtxtHandle);
    }
}


unittest
{
    import urt.mem : alloc, free;

    class Transport : Stream
    {
    nothrow @nogc:

        ~this() {}

        enum type_name = "test-transport";

        this(CID id, ObjectFlags flags = ObjectFlags.none)
        {
            super(collection_type_info!Transport, id, flags);
        }

        override ptrdiff_t write(const(void[])[] data...)
            => 0;
    }

    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();

    TLSStream tls = alloc!TLSStream(CID(1));
    scope (exit) free(tls);

    tls._tx_pending = page_alloc(4);
    tls._handshake_state = TLSStream.HandshakeState.completed;
    tls.fail_session();
    assert(tls._tx_pending is null && tls._handshake_state == TLSStream.HandshakeState.failed);
    ubyte[1] more;
    assert(tls.write(more[]) == -1);

    // once established, ciphertext that arrives with no consumer pauses the transport, so no more is read
    {
        TLSStream session = alloc!TLSStream(CID(3));
        scope (exit) free(session);
        Transport transport = alloc!Transport(CID(4));
        scope (exit) free(transport);
        session._handshake_state = TLSStream.HandshakeState.completed;
        transport.rx_handler(&session.inner_rx);
        ubyte[4] record = [23, 3, 3, 0];
        session.inner_rx(transport, record[], MonoTime());
        assert(session._receive_buffer[] == record[] && transport.rx_handler is null);
        session._receive_buffer.clear();
    }
}

}
