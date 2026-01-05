module protocol.http.tls;

import urt.array;
import urt.log;
import urt.mem;
import urt.mem.temp;
import urt.socket;
import urt.string;

import manager;
import manager.base;
import manager.collection;

import protocol.http;

import router.stream;
import router.stream.tcp;

version (Windows)
{
    import core.sys.windows.ntsecpkg;
    import core.sys.windows.schannel;
    import core.sys.windows.security;
    import core.sys.windows.sspi;
    import core.sys.windows.wincrypt;
    import core.sys.windows.windows;

    pragma(lib, "Secur32");
}

//version = DebugTLS;

nothrow @nogc:


class TLSStream : Stream
{
    __gshared Property[4] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("remote", remote)(),
                                         Property.create!("keepalive", keepalive)(),
                                         Property.create!("private_key", private_key)() ];
nothrow @nogc:

    alias TypeName = StringLit!"tls";

    this(String name, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!TLSStream, name.move, flags, options);
    }

    // Properties...
    inout(Stream) stream() inout pure
        => _stream.get();
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        if (value == _stream)
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
        if (TCPStream tcp = cast(TCPStream)_stream)
            tcp.keepalive = value;
    }

    void private_key(ubyte[] value)
    {
        assert(false, "TODO: implement server mode");
    }

    // API...

    final override bool validate() const pure
    {
        return !_host.empty;
    }

    final override CompletionStatus startup()
    {
        if (!_stream)
        {
            // prevent duplicate stream names...
            String new_name = get_module!StreamModule.streams.generate_name(name).makeString(defaultAllocator());
            _stream = get_module!TCPStreamModule.tcp_streams.create(new_name.move, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("keepalive", _keep_enable), NamedArgument("remote", _host));
            if (!_stream)
            {
                version (DebugTLS)
                    writeErrorf("Failed to create underlying TCP stream");
                return CompletionStatus.error;
            }
        }
        if (!_stream.running)
            return CompletionStatus.continue_;

        version (Windows)
        {
            if (_handshake_state == HandshakeState.NotStarted)
                init_context(false, null); // TODO: server mode?

            if (_handshake_state == HandshakeState.InProgress)
            {
                while (true)
                {
                    ubyte[8192] read_buffer = void;
                    ptrdiff_t bytes_received = _stream.read(read_buffer[]);
                    if (bytes_received == 0)
                        break;
                    else if (bytes_received < 0)
                    {
                        _handshake_state = HandshakeState.Failed;
                        return CompletionStatus.error;
                    }
                    _receive_buffer ~= read_buffer[0 .. bytes_received];
                    advance_handshake(_host, false);
                }
            }
            if (_handshake_state == HandshakeState.Completed)
                return CompletionStatus.complete;
            if (_handshake_state == HandshakeState.Failed)
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

        if (_stream)
            _stream.destroy();
        _stream = null;

        _remote = InetAddress();
        version(Windows)
            _handshake_state = HandshakeState.NotStarted;

        return CompletionStatus.complete;
    }

    final override void update()
    {
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
                    version (DebugTLS) writeInfo("TLS renegotiation requested");
                    _handshake_state = HandshakeState.Failed; // Or handle properly
                    return;
                }
                else if (status == SEC_E_INCOMPLETE_MESSAGE)
                {
                    // Not enough data to form a full TLS record, wait for more.
                    return;
                }

                if (status != SEC_E_OK)
                {
                    version(DebugTLS) writeErrorf("Decryption failed: %x", status);
                    _handshake_state = HandshakeState.Failed;
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
                {
                    // This is un-decrypted data, move it to the front of the buffer.
                    _receive_buffer.remove(0, _receive_buffer.length - extra_buf.cbBuffer);
                }
                else
                {
                    _receive_buffer.clear();
                }
            }
        }
    }

    override bool connect()
    {
        assert(false);
    }

    override void disconnect()
    {
        assert(false);
    }

    override const(char)[] remote_name()
        => _stream ? _stream.remote_name : null;

    final override ptrdiff_t read(void[] buffer)
    {
        assert(false);
        return 0;
    }

    final override ptrdiff_t write(const void[] data)
    {
        version (Windows)
        {
            if (_handshake_state != HandshakeState.Completed)
                return -1;

            SecPkgContext_StreamSizes sizes;
            auto status = QueryContextAttributesA(&_context, SECPKG_ATTR_STREAM_SIZES, &sizes);
            if (status != SEC_E_OK)
                return -1;

            SecBuffer[4] bufs;
            auto buffer = Array!(ubyte)(Alloc, sizes.cbHeader + sizes.cbTrailer);

            bufs[0].pvBuffer = &buffer[0];
            bufs[0].cbBuffer = sizes.cbHeader;
            bufs[0].BufferType = SECBUFFER_STREAM_HEADER;

            bufs[1].pvBuffer = cast(void*)data.ptr;
            bufs[1].cbBuffer = cast(ULONG)data.length;
            bufs[1].BufferType = SECBUFFER_DATA;

            bufs[2].pvBuffer = &buffer[sizes.cbHeader];
            bufs[2].cbBuffer = sizes.cbTrailer;
            bufs[2].BufferType = SECBUFFER_STREAM_TRAILER;

            bufs[3].pvBuffer = null;
            bufs[3].cbBuffer = 0;
            bufs[3].BufferType = SECBUFFER_EMPTY;

            SecBufferDesc buf_desc;
            buf_desc.ulVersion = 0;
            buf_desc.cBuffers = 4;
            buf_desc.pBuffers = bufs.ptr;

            status = EncryptMessage(&_context, 0, &buf_desc, 0);
            if (status != SEC_E_OK)
                return -1;

            ptrdiff_t bytes_sent = _stream.write(buffer[0 .. sizes.cbHeader]);
            if (bytes_sent != buffer.length)
                return -1;
            bytes_sent = _stream.write(data);
            if (bytes_sent != data.length)
                return -1;
            bytes_sent = _stream.write(buffer[sizes.cbHeader .. $]);
            if (bytes_sent != buffer.length)
                return -1;
            return data.length;
        }
        else
            return -1;
    }

    final override ptrdiff_t pending()
    {
        // pending TLS bytes?
        assert(0);
    }

    final override ptrdiff_t flush()
    {
        // TODO: read until can't read no more?
        assert(0);
    }

private:
    String _host;
    InetAddress _remote;
    bool _keep_enable = false;

    ObjectRef!Stream _stream;
    Array!ubyte _receive_buffer;

    void incoming_message(const(void)[] message)
    {
        // buffer these bytes for read()...
        assert(false);
    }

    version (Windows)
    {
        enum HandshakeState
        {
            NotStarted,
            Initializing,
            InProgress,
            Completed,
            Failed,
        }

        CredHandle _credentials;
        CtxtHandle _context;
        HandshakeState _handshake_state;

        void init_context(bool is_server, const(CERT_CONTEXT)* pCertContext)
        {
            SCHANNEL_CRED creds;
            creds.dwVersion = SCHANNEL_CRED_VERSION;
            creds.grbitEnabledProtocols = 0;
            if (is_server)
            {
                creds.cCreds = 1;
                creds.paCred = cast(const(CERT_CONTEXT)**)&pCertContext;
                creds.dwFlags |= SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS;
            }
            else
            {
                creds.dwFlags = SCH_CRED_AUTO_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS;
            }

            auto status = AcquireCredentialsHandleA(null, cast(char*)UNISP_NAME_A.ptr, is_server ? SECPKG_CRED_INBOUND : SECPKG_CRED_OUTBOUND, null, &creds, null, null, &_credentials, null);
            if (status != SEC_E_OK)
            {
                version(DebugTLS) writeErrorf("AcquireCredentialsHandleA failed: %x", status);
                _handshake_state = HandshakeState.Failed;
                return;
            }

            _handshake_state = HandshakeState.Initializing;

            // For a client, we kick off the handshake immediately.
            if (!is_server)
            {
                _handshake_state = HandshakeState.InProgress;
                advance_handshake(_host, false);
            }
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
                DWORD sspi_flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
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
                    status = AcceptSecurityContext(&_credentials, data.length ? &_context : null, &in_buf_desc, sspi_flags, 0, &_context, &out_buf_desc, &sspi_out_flags, null);
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
                        version (DebugTLS) writeErrorf("Failed to send handshake token");
                        _handshake_state = HandshakeState.Failed;
                        break; // Exit loop on error
                    }
                }

                if (status == SEC_E_OK)
                {
                    _handshake_state = HandshakeState.Completed;
                    consumed += data.length;
                }
                else if (status == SEC_I_CONTINUE_NEEDED)
                {
                    _handshake_state = HandshakeState.InProgress;
                    consumed += data.length;
                }
                else if (status == SEC_E_INCOMPLETE_MESSAGE)
                    break; // Need more data, break the loop and wait for the next poll.
                else if (status == SEC_I_RENEGOTIATE)
                {
                    version(DebugTLS) writeInfo("TLS renegotiation requested");
                    _handshake_state = HandshakeState.Failed; // TODO: Handle renegotiation
                    break;
                }
                else
                {
                    version(DebugTLS) writeErrorf("Handshake failed with status: %x", status);
                    _handshake_state = HandshakeState.Failed;
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

class TLSServer : TCPServer
{
nothrow @nogc:
    alias TypeName = StringLit!"tls-server";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!TLSServer, name.move, flags);
    }

protected:
    final override Stream create_stream(Socket conn)
    {
        Stream tcp = super.create_stream(conn);
        return get_module!HTTPModule.tls_streams.create(tcp.name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("stream", tcp));
    }
}


private:

version (Windows)
{
    extern (Windows)
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
