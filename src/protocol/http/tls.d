module protocol.http.tls;

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.socket;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.certificate : Certificate;
import manager.collection;

import protocol.http;

import router.stream;
import router.stream.tcp;

version (Windows)
{
    import urt.internal.sys.windows;
    import urt.internal.sys.windows.ntsecpkg;
    import urt.internal.sys.windows.schannel;
    import urt.internal.sys.windows.security;
    import urt.internal.sys.windows.sspi;
    import urt.internal.sys.windows.wincrypt;

    pragma(lib, "Secur32");
}
else version (Posix)
{
    import urt.internal.mbedtls;
}

version = DebugTLS;

nothrow @nogc:


class TLSStream : Stream
{
    alias Properties = AliasSeq!(Prop!("stream", stream),
                                 Prop!("remote", remote),
                                 Prop!("keepalive", keepalive),
                                 Prop!("certificate", certificate),
                                 Prop!("certificates", certificates));
nothrow @nogc:

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
        _stream = value;
        restart();
        return null;
    }

    ref const(String) remote() const pure
        => _host;
    const(char)[] remote(String value)
    {
        if (value.empty)
            return "remote cannot be empty";
        if (value == _host)
            return null;
        _host = value.move;
        restart();
        return null;
    }

    bool keepalive() const pure
        => _keep_enable;
    void keepalive(bool value)
    {
        if (_keep_enable == value)
            return;
        _keep_enable = value;
        if (TCPStream tcp = cast(TCPStream)_stream)
            tcp.keepalive = value;
    }

    void certificate(Certificate value)
    {
        _certificates.clear();
        if (value)
            _certificates.emplaceBack(value);
        restart();
    }

    void certificates(Certificate[] value...)
    {
        _certificates.clear();
        _certificates.reserve(value.length);
        foreach (c; value)
            _certificates.emplaceBack(c);
        restart();
    }

    // API...

    String selected_cert_name() const pure
        => _selected_cert ? _selected_cert.name : String();

    final override bool validate() const pure
    {
        // Server mode: need a certificate. Client mode: need a remote host.
        if (_certificates.length > 0)
            return true;
        return !_host.empty;
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

            // Client-mode: create a TCP stream to connect outward.
            const(char)[] new_name = Collection!Stream().generate_name(name[]);
            _stream = cast(Stream)Collection!TCPStream().create(new_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("keepalive", _keep_enable), NamedArgument("remote", _host));
            if (!_stream)
            {
                log.error("failed to create underlying TCP stream");
                return CompletionStatus.error;
            }
        }
        if (!_stream.running)
        {
            // Server-mode: the TCP stream was created already running.
            // If it's no longer running, the peer disconnected.
            if (is_server && _handshake_start != SysTime())
                return CompletionStatus.error;
            return CompletionStatus.continue_;
        }

        // Start handshake timeout when the stream first becomes available.
        if (_handshake_start == SysTime())
            _handshake_start = getSysTime();

        if (_handshake_state == HandshakeState.not_started)
        {
            if (is_server)
            {
                // Buffer ClientHello for SNI extraction
                ubyte[8192] buf = void;
                ptrdiff_t n = _stream.read(buf[]);
                if (n > 0)
                    _receive_buffer ~= buf[0 .. n];

                // Wait for full TLS record
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
                            if (auto cert = cast(Certificate)c.get())
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

            version (Windows)
            {
                if (is_server)
                {
                    init_context(true, cast(const(CERT_CONTEXT)*)(cast(Certificate)_selected_cert).get_cert_context());
                    // process the already-buffered ClientHello
                    if (_handshake_state == HandshakeState.in_progress)
                        advance_handshake(_host[], true);
                }
                else
                    init_context(false, null);
            }
            else version (Posix)
            {
                if (is_server)
                    init_mbedtls_context(true, cast(Certificate)_selected_cert);
                else
                    init_mbedtls_context(false, null);
            }
        }

        if (_handshake_state == HandshakeState.in_progress)
        {
            version (Windows)
            {
                while (true)
                {
                    ubyte[8192] read_buffer = void;
                    ptrdiff_t bytes_received = _stream.read(read_buffer[]);
                    if (bytes_received == 0)
                        break;
                    else if (bytes_received < 0)
                    {
                        _handshake_state = HandshakeState.failed;
                        return CompletionStatus.error;
                    }
                    _receive_buffer ~= read_buffer[0 .. bytes_received];
                    advance_handshake(_host[], is_server);
                }
            }
            else version (Posix)
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
        }

        if (_handshake_state == HandshakeState.completed)
        {
            if (_selected_cert)
                log.info("HTTPS session from ", _stream.remote_name, " cert='", _selected_cert.name, "'");
            else
                log.info("connected to ", _stream.remote_name);
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
        version (Windows)
        {
            if (_context.dwLower != 0 || _context.dwUpper != 0)
                DeleteSecurityContext(&_context);
            if (_credentials.dwLower != 0 || _credentials.dwUpper != 0)
                FreeCredentialsHandle(&_credentials);
        }
        else version (Posix)
        {
            free_mbedtls_contexts();
        }

        _app_buffer.clear();
        _close_notify = false;
        _selected_cert = null;
        _handshake_start = SysTime();

        if (_stream)
            _stream.destroy();
        _stream = null;

        _handshake_state = HandshakeState.not_started;

        return CompletionStatus.complete;
    }

    final override void update()
    {
        if (!_stream || !_stream.running || _handshake_state == HandshakeState.failed)
        {
            restart();
            return;
        }

        // After close_notify, just check if consumer drained _app_buffer
        if (_close_notify)
        {
            if (_app_buffer.length == 0)
                restart();
            return;
        }

        version (Windows)
        {
            ubyte[8192] read_buffer = void;
            ptrdiff_t bytes_received = _stream.read(read_buffer[]);
            if (bytes_received < 0)
            {
                // TODO: handle error?? restart maybe? we need a policy around this!
                return;
            }
            if (bytes_received > 0)
                _receive_buffer ~= read_buffer[0 .. bytes_received];

            while (_receive_buffer.length > 0)
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

                // Find and process the decrypted application data.
                SecBuffer* data_buf = null;
                for (int i = 0; i < 4; ++i)
                {
                    if (bufs[i].BufferType == SECBUFFER_DATA)
                    {
                        data_buf = &bufs[i];
                        break;
                    }
                }

                if (data_buf !is null)
                    incoming_message( (cast(ubyte*)data_buf.pvBuffer)[0 .. data_buf.cbBuffer] );

                // Find any leftover data from the transport.
                SecBuffer* extra_buf = null;
                for (int i = 0; i < 4; ++i)
                {
                    if (bufs[i].BufferType == SECBUFFER_EXTRA)
                    {
                        extra_buf = &bufs[i];
                        break;
                    }
                }

                if (extra_buf !is null)
                    _receive_buffer.remove(0, _receive_buffer.length - extra_buf.cbBuffer);
                else
                    _receive_buffer.clear();
            }
        }
        else version (Posix)
        {
            ubyte[8192] read_buf = void;
            while (true)
            {
                int ret = mbedtls_ssl_read(_ssl, read_buf.ptr, read_buf.length);
                if (ret > 0)
                    incoming_message(read_buf[0 .. ret]);
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
    }

    override bool connect()
        => false;

    override void disconnect() {}

    override const(char)[] remote_name()
        => _stream ? _stream.remote_name : null;

    final override ptrdiff_t read(void[] buffer)
    {
        if (_app_buffer.length == 0)
            return 0;
        size_t n = buffer.length < _app_buffer.length ? buffer.length : _app_buffer.length;
        buffer[0 .. n] = _app_buffer[0 .. n];
        _app_buffer.remove(0, n);
        return n;
    }

    final override ptrdiff_t write(const(void[])[] data...)
    {
        if (_handshake_state != HandshakeState.completed)
        {
            version (DebugTLS)
                log.trace("write rejected, handshake state=", _handshake_state);
            return -1;
        }

        ptrdiff_t result = -1;

        version (Windows)
        {
            SecPkgContext_StreamSizes sizes;
            auto status = QueryContextAttributesA(&_context, SECPKG_ATTR_STREAM_SIZES, &sizes);
            if (status != SEC_E_OK)
            {
                log.errorf("QueryContextAttributes failed: {0,08x}", cast(uint)status);
                return -1;
            }

            SecBuffer[35] bufs = void;
            assert(data.length <= bufs.length - 3, "Too many buffers!");

            auto buffer = Array!(ubyte)(Alloc, sizes.cbHeader + sizes.cbTrailer);

            bufs[0].pvBuffer = &buffer[0];
            bufs[0].cbBuffer = sizes.cbHeader;
            bufs[0].BufferType = SECBUFFER_STREAM_HEADER;

            ULONG i = 1;
            foreach (ref d; data)
            {
                assert(d.length <= ULONG.max, "Buffer too large for Windows API");
                bufs[i].pvBuffer = cast(void*)d.ptr;
                bufs[i].cbBuffer = cast(ULONG)d.length;
                bufs[i++].BufferType = SECBUFFER_DATA;
            }

            bufs[i].pvBuffer = &buffer[sizes.cbHeader];
            bufs[i].cbBuffer = sizes.cbTrailer;
            bufs[i++].BufferType = SECBUFFER_STREAM_TRAILER;

            bufs[i].pvBuffer = null;
            bufs[i].cbBuffer = 0;
            bufs[i++].BufferType = SECBUFFER_EMPTY;

            SecBufferDesc buf_desc;
            buf_desc.ulVersion = 0;
            buf_desc.cBuffers = i;
            buf_desc.pBuffers = bufs.ptr;

            status = EncryptMessage(&_context, 0, &buf_desc, 0);
            if (status != SEC_E_OK)
            {
                log.errorf("EncryptMessage failed: {0,08x}", cast(uint)status);
                return -1;
            }

            ref SecBuffer hdr = bufs[0];
            ref SecBuffer tail = bufs[buf_desc.cBuffers - 2];

            const(void)[][34] send_bufs = void;
            size_t total_len = hdr.cbBuffer + tail.cbBuffer;
            send_bufs[0] = hdr.pvBuffer[0 .. hdr.cbBuffer];
            send_bufs[1 + data.length] = tail.pvBuffer[0 .. tail.cbBuffer];
            size_t data_len = 0;
            for (i = 1; i <= data.length; ++i)
            {
                data_len += bufs[i].cbBuffer;
                send_bufs[i] = bufs[i].pvBuffer[0 .. bufs[i].cbBuffer];
            }
            total_len += data_len;

            ptrdiff_t bytes_sent = _stream.write(send_bufs[0 .. 2 + data.length]);
            if (bytes_sent != total_len)
            {
                log.warning("underlying write failed: sent=", bytes_sent, " expected=", total_len);
                return -1;
            }

            result = data_len;
        }
        else version (Posix)
        {
            ptrdiff_t total = 0;
            foreach (ref d; data)
            {
                auto chunk = cast(const(ubyte)[])d;
                while (chunk.length > 0)
                {
                    int ret = mbedtls_ssl_write(_ssl, chunk.ptr, chunk.length);
                    if (ret > 0)
                    {
                        chunk = chunk[ret .. $];
                        total += ret;
                    }
                    else
                        return -1;
                }
            }

            result = total;
        }

        if (result >= 0 && _logging)
        {
            foreach (ref d; data)
                write_to_log(false, d[]);
        }
        return result;
    }

    final override ptrdiff_t pending()
        => _app_buffer.length;

    final override ptrdiff_t flush()
    {
        size_t n = _app_buffer.length;
        _app_buffer.clear();
        return n;
    }

protected:
    mixin RekeyHandler;

private:
    String _host;
    bool _keep_enable = false;
    bool _close_notify = false;

    Array!(ObjectRef!Certificate) _certificates;
    BaseObject _selected_cert;
    ObjectRef!Stream _stream;
    Array!ubyte _receive_buffer;
    Array!ubyte _app_buffer;
    SysTime _handshake_start;

    void incoming_message(const(void)[] message)
    {
        _app_buffer ~= cast(const(ubyte)[])message;
    }

    Certificate select_certificate()
    {
        const(char)[] sni = extract_sni_hostname(_receive_buffer[]);

        if (sni.length > 0)
        {
            // Exact domain match
            foreach (ref c; _certificates)
            {
                if (auto cert = cast(Certificate)c.get())
                    if (cert.is_valid && cert.domain[] == sni)
                        return c.get();
            }
        }

        // Fallback: first cert with no domain (self-signed)
        foreach (ref c; _certificates)
        {
            if (auto cert = cast(Certificate)c.get())
                if (cert.is_valid && cert.domain[].empty)
                    return c.get();
        }

        // Last resort: first valid cert
        foreach (ref c; _certificates)
        {
            if (auto cert = cast(Certificate)c.get())
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

    version (Windows)
    {
        CredHandle _credentials;
        CtxtHandle _context;

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
                advance_handshake(_host[], false);
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
    else version (Posix)
    {
        mbedtls_ssl_context* _ssl;
        mbedtls_ssl_config* _ssl_conf;
        mbedtls_entropy_context* _entropy;
        mbedtls_ctr_drbg_context* _ctr_drbg;

        void init_mbedtls_context(bool is_server, Certificate cert)
        {
            _entropy = urt_entropy_new();
            _ctr_drbg = urt_ctr_drbg_new();
            if (_entropy is null || _ctr_drbg is null)
            {
                free_mbedtls_contexts();
                _handshake_state = HandshakeState.failed;
                return;
            }

            int ret = mbedtls_ctr_drbg_seed(_ctr_drbg, &mbedtls_entropy_func, cast(void*)_entropy, null, 0);
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

            mbedtls_ssl_conf_rng(_ssl_conf, &mbedtls_ctr_drbg_random, cast(void*)_ctr_drbg);

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

            if (!is_server && !_host.empty)
            {
                auto host = _host[];
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
            if (_ctr_drbg !is null)
            {
                urt_ctr_drbg_delete(_ctr_drbg);
                _ctr_drbg = null;
            }
            if (_entropy !is null)
            {
                urt_entropy_delete(_entropy);
                _entropy = null;
            }
        }
    }
}

class TLSServer : TCPServer
{
    alias Properties = AliasSeq!(Prop!("certificate", certificate),
                                 Prop!("certificates", certificates));
nothrow @nogc:
    enum type_name = "tls-server";
    enum path = "/protocol/tls/server";
    enum collection_id = CollectionType.tls_server;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TLSServer, id, flags);
    }

    void certificate(ActiveObject value)
    {
        _certificates.clear();
        if (value)
            _certificates.emplaceBack(value);
        restart();
    }

    void certificates(ActiveObject[] value...)
    {
        _certificates.clear();
        _certificates.reserve(value.length);
        foreach (c; value)
            _certificates.emplaceBack(c);
        restart();
    }

protected:
    mixin RekeyHandler;

    final override bool validate() const pure
        => super.validate() && _certificates.length > 0;

    final override CompletionStatus startup()
    {
        foreach (ref cert; _certificates[])
            if (cert && cert.running)
                return super.startup();
        return CompletionStatus.continue_;
    }

    final override Stream create_stream(Socket conn)
    {
        version (DebugTLS)
        {
            InetAddress addr;
            Result r = conn.get_peer_name(addr);
            log.trace("creating TLS stream for connection from ", r ? addr : InetAddress());
        }

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
        auto tls = cast(TLSStream)Collection!TLSStream().create(stream_name[], cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
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

package:

    void set_certificate_array(ObjectRef!Certificate[] certs)
    {
        _certificates.clear();
        _certificates.reserve(certs.length);
        foreach (ref c; certs)
            if (c)
                _certificates.emplaceBack(c.get());
    }

private:

    Array!(ObjectRef!ActiveObject) _certificates;
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

version (Posix)
{
    // BIO callbacks for mbedtls; called during ssl_handshake, ssl_read, ssl_write
    // p_bio is the TLSStream instance (set via mbedtls_ssl_set_bio)

    extern(C) int tls_bio_recv(void* ctx, ubyte* buf, size_t len) nothrow @nogc
    {
        auto self = cast(TLSStream)ctx;

        // drain any pre-buffered data (e.g., ClientHello read before mbedtls init)
        if (self._receive_buffer.length > 0)
        {
            size_t n = len < self._receive_buffer.length ? len : self._receive_buffer.length;
            buf[0 .. n] = self._receive_buffer[0 .. n];
            self._receive_buffer.remove(0, n);
            return cast(int)n;
        }

        ptrdiff_t n = self._stream.read(buf[0 .. len]);
        if (n > 0)
            return cast(int)n;
        return MBEDTLS_ERR_SSL_WANT_READ;
    }

    extern(C) int tls_bio_send(void* ctx, const(ubyte)* buf, size_t len) nothrow @nogc
    {
        auto self = cast(TLSStream)ctx;
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
