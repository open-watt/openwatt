module manager.certificate;

import urt.array;
import urt.crypto.pem;
import urt.crypto.pki;
import urt.digest.sha;
import urt.encoding;
import urt.file;
import urt.format.json;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.time;
import urt.variant;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import protocol.http;
import protocol.http.client;
import protocol.http.message;
import protocol.http.server;

import router.stream;


version = DebugCertificate;

nothrow @nogc:


enum CertType
{
    certificate,
    self_signed,
    acme,
}

enum CertStatus
{
    none,
    pending,
    issued,
    expired,
    error,
}

class Certificate : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("cert-type", cert_type),
                                 Prop!("domain", domain),
                                 Prop!("email", email),
                                 Prop!("certificate_file", certificate_file),
                                 Prop!("key_file", key_file),
                                 Prop!("http-server", http_server),
                                 Prop!("uri", uri),
                                 Prop!("cert-status", cert_status),
                                 Prop!("expiry", expiry));
nothrow @nogc:

    enum type_name = "certificate";
    enum path = "/certificate";
    enum collection_id = CollectionType.certificate;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Certificate, id, flags);
    }

    // Properties...

    CertType cert_type() const pure
        => _type;
    void cert_type(CertType value)
    {
        if (_type == value)
            return;
        _type = value;
        restart();
    }

    ref const(String) domain() const pure
        => _domain;
    const(char)[] domain(String value)
    {
        if (value.empty)
            return "domain cannot be empty";
        if (value == _domain)
            return null;
        _domain = value.move;
        restart();
        return null;
    }

    ref const(String) email() const pure
        => _email;
    void email(String value)
    {
        if (value == _email)
            return;
        _email = value.move;
        restart();
    }

    ref const(String) certificate_file() const pure
        => _cert_file;
    const(char)[] certificate_file(String value)
    {
        if (value == _cert_file)
            return null;
        _cert_file = value.move;
        _type = CertType.certificate;
        restart();
        return null;
    }

    ref const(String) key_file() const pure
        => _key_file;
    const(char)[] key_file(String value)
    {
        if (value == _key_file)
            return null;
        _key_file = value.move;
        _type = CertType.certificate;
        restart();
        return null;
    }

    inout(HTTPServer) http_server() inout pure
        => _http_server;
    void http_server(HTTPServer value)
    {
        if (_http_server is value)
            return;
        _http_server = value;
        restart();
    }

    const(char)[] uri() const pure
        => _uri[];
    void uri(const(char)[] value)
    {
        _uri = value.makeString(g_app.allocator);
        restart();
    }

    CertStatus cert_status() const pure
        => _status;

    SysTime expiry() const pure
        => _expiry;

    override const(char)[] status_message() const
    {
        if (_status_msg.length > 0)
            return _status_msg[];
        return super.status_message();
    }

    // API...

    inout(void)* get_cert_context() inout
        => _certref.native_cert_context();

    inout(void)* get_key_context() inout
    {
        version (Posix)
            return cast(inout(void)*)&_keypair.pk;
        else
            return null;
    }

    bool is_valid() const pure
        => _status == CertStatus.issued && running;

protected:
    override bool validate() const
    {
        final switch (_type)
        {
            case CertType.certificate:
                if (_cert_file.empty || _key_file.empty)
                {
                    writeError("Certificate '", name, "': certificate type requires certificate_file and key_file");
                    return false;
                }
                return true;

            case CertType.self_signed:
                return true;

            case CertType.acme:
                if (_domain.empty)
                {
                    writeError("Certificate '", name, "': acme type requires domain");
                    return false;
                }
                return true;
        }
    }

    override CompletionStatus startup()
    {
        final switch (_type)
        {
            case CertType.certificate:
                return start_certificate();
            case CertType.self_signed:
                return start_self_signed();
            case CertType.acme:
                return start_acme();
        }
    }

    override void update()
    {
        if (_type != CertType.acme)
            return;

        // Drive in-progress renewal
        if (_renewing)
        {
            update_acme();
            return;
        }

        // Check if renewal is needed (~30 days before expiry)
        if (_expiry && _expiry - getSysTime() < dur!"days"(30)
            && getTime() >= _next_renewal_attempt)
        {
            start_renewal();
        }
    }

    override CompletionStatus shutdown()
    {
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': shutdown");

        unregister_challenge_endpoint();
        unload_cert();
        _acme_state = AcmeState.idle;
        _renewing = false;
        _status = CertStatus.none;
        return CompletionStatus.complete;
    }

private:
    CertType _type;
    CertStatus _status;

    ObjectRef!HTTPServer _http_server;

    String _domain;
    String _email;
    String _cert_file;
    String _key_file;
    String _uri;

    MutableString!0 _status_msg;
    SysTime _expiry;

    KeyPair _keypair;       // live cert's private key (only set when cert is issued)
    CertRef _certref;       // live cert context (only set when cert is issued)

    // ACME state
    enum AcmeState
    {
        idle,
        need_directory,     // fetch ACME directory
        need_nonce,         // get fresh replay nonce
        need_account,       // register account with ACME
        need_order,         // create new order for domain
        need_authorization, // fetch authorization, extract challenge
        challenge_pending,  // signal challenge ready to ACME
        challenge_waiting,  // waiting for ACME to validate challenge
        need_finalize,      // submit CSR to finalize URL
        cert_pending,       // waiting for certificate to be ready
    }

    AcmeState _acme_state;
    bool _request_pending;
    bool _renewing;                 // true when renewal is running in update()
    MonoTime _next_poll_time;
    MonoTime _next_renewal_attempt; // retry backoff for renewal failures
    uint _renewal_failures;
    KeyPair _renewal_keypair;       // pending cert key (used during ACME workflow)
    KeyPair _account_key;           // ECDSA P-256 account key for JWS
    Array!ubyte _account_pub_x;     // raw X coordinate (32 bytes)
    Array!ubyte _account_pub_y;     // raw Y coordinate (32 bytes)
    HTTPClient _acme_client;
    String _challenge_token;        // HTTP-01 challenge token
    String _challenge_auth;         // token.thumbprint key authorization
    String _acme_nonce;
    String _acme_account_url;       // account URL (kid) for subsequent requests
    String _new_nonce_url;
    String _new_account_url;
    String _new_order_url;
    String _acme_authz_url;
    String _acme_challenge_url;
    String _acme_finalize_url;
    String _acme_cert_url;
    bool _challenge_registered;
    bool _owns_http_server;

    CompletionStatus start_certificate()
    {
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': loading from files cert='", _cert_file, "' key='", _key_file, "'");

        auto cert_data = cast(ubyte[])load_file(_cert_file[]);
        if (cert_data is null)
        {
            writeError("Certificate '", name, "': failed to read certificate file '", _cert_file, "'");
            _status = CertStatus.error;
            return CompletionStatus.error;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': read cert file, ", cast(uint)cert_data.length, " bytes");

        auto key_data = cast(ubyte[])load_file(_key_file[]);
        if (key_data is null)
        {
            writeError("Certificate '", name, "': failed to read key file '", _key_file, "'");
            _status = CertStatus.error;
            return CompletionStatus.error;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': read key file, ", cast(uint)key_data.length, " bytes");

        auto r = cert_data.load_certificate(_certref);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to load certificate, err={1,08x}", name, r.system_code);
            _status = CertStatus.error;
            return CompletionStatus.error;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': certificate loaded into store");

        r = key_data.import_private_key(_keypair);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to load private key, err={1,08x}", name, r.system_code);
            _certref.free_cert();
            _status = CertStatus.error;
            return CompletionStatus.error;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': private key imported");

        r = _certref.associate_key(_keypair);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to associate key with certificate, err={1,08x}", name, r.system_code);
            _certref.free_cert();
            _keypair.free_keypair();
            _status = CertStatus.error;
            return CompletionStatus.error;
        }

        _expiry = _certref.cert_expiry();
        _status = CertStatus.issued;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': issued, context=", cast(ulong)_certref.native_cert_context());
        writeInfo("Certificate '", name, "': loaded from files");
        return CompletionStatus.complete;
    }

    CompletionStatus start_self_signed()
    {
        import manager.system : hostname;
        const(char)[] cn = _domain.empty ? hostname[] : _domain[];

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': generating self-signed for '", cn, "'");

        auto r = generate_keypair(_keypair);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to generate key pair, err={1,08x}", name, r.system_code);
            _status = CertStatus.error;
            return CompletionStatus.error;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': ECDSA P-256 key pair generated");

        r = create_self_signed(_keypair, _certref, cn, hostname[]);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to create self-signed certificate, err={1,08x}", name, r.system_code);
            _keypair.free_keypair();
            _status = CertStatus.error;
            return CompletionStatus.error;
        }

        r = _certref.associate_key(_keypair);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to associate key with self-signed certificate, err={1,08x}", name, r.system_code);
            _certref.free_cert();
            _keypair.free_keypair();
            _status = CertStatus.error;
            return CompletionStatus.error;
        }

        _expiry = _certref.cert_expiry();
        _status = CertStatus.issued;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': self-signed issued, context=", cast(ulong)_certref.native_cert_context());
        writeInfo("Certificate '", name, "': self-signed certificate generated for '", cn, "'");
        return CompletionStatus.complete;
    }

    CompletionStatus start_acme()
    {
        // ACME error occurred asynchronously — trigger ActiveObject backoff
        if (_status == CertStatus.error)
            return CompletionStatus.error;

        // Drive existing ACME workflow — don't re-initialize
        if (_acme_state != AcmeState.idle)
        {
            update_acme();
            return _status == CertStatus.issued ? CompletionStatus.complete : CompletionStatus.continue_;
        }

        _status_msg.clear();

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': starting ACME for '", _domain, "'");

        // Try loading a previously cached cert from disk
        if (try_load_cached_cert())
            return CompletionStatus.complete;

        // Auto-create a temporary HTTP server on port 80 if none supplied
        if (!_http_server)
        {
            version (DebugCertificate)
                writeDebug("Certificate '", name, "': creating temporary HTTP server on port 80");
            const(char)[] server_name = Collection!HTTPServer().generate_name(name[]);
            _http_server = Collection!HTTPServer().create(
                server_name, ObjectFlags.dynamic,
                NamedArgument("port", cast(ushort)80));
            _owns_http_server = true;
        }

        if (!_http_server || !_http_server.running)
        {
            version (DebugCertificate)
                writeDebug("Certificate '", name, "': waiting for HTTP server");
            _status_msg.concat("waiting for HTTP server");
            return CompletionStatus.continue_;
        }

        // Generate ECDSA P-256 key pair for the pending certificate (used for CSR at finalize)
        auto r = generate_keypair(_renewal_keypair);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to generate certificate key pair, err={1,08x}", name, r.system_code);
            _status = CertStatus.error;
            return CompletionStatus.error;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': ECDSA P-256 certificate key pair generated");

        // Try loading cached ACME account (key + URL) to avoid re-registration
        if (try_load_acme_account())
        {
            writeInfo("Certificate '", name, "': loaded cached ACME account");
        }
        else
        {
            r = generate_keypair(_account_key);
            if (!r)
            {
                writeErrorf("Certificate '{0}': failed to generate ACME account key, err={1,08x}", name, r.system_code);
                _status = CertStatus.error;
                return CompletionStatus.error;
            }
            version (DebugCertificate)
                writeDebug("Certificate '", name, "': ECDSA P-256 account key generated");
        }

        // Export account public key for JWK thumbprint
        r = _account_key.export_public_key_raw(_account_pub_x, _account_pub_y);
        if (!r)
        {
            writeErrorf("Certificate '{0}': failed to export account public key, err={1,08x}", name, r.system_code);
            _status = CertStatus.error;
            return CompletionStatus.error;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': account pubkey exported, x=", cast(uint)_account_pub_x.length, "B y=", cast(uint)_account_pub_y.length, "B");

        // Register challenge endpoint on the HTTP server
        register_challenge_endpoint();

        // Create HTTP client for ACME API requests
        const(char)[] client_name = Collection!HTTPClient().generate_name(name[]);
        _acme_client = Collection!HTTPClient().create(
            client_name, ObjectFlags.dynamic,
            NamedArgument("remote", "https://acme-v02.api.letsencrypt.org"));

        if (!_acme_client)
        {
            writeError("Certificate '", name, "': failed to create ACME HTTP client");
            _status = CertStatus.error;
            return CompletionStatus.error;
        }

        _acme_state = AcmeState.need_directory;
        _status = CertStatus.pending;
        _status_msg.concat("ACME: connecting to Let's Encrypt");
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': ACME init complete, state -> need_directory");
        writeInfo("Certificate '", name, "': starting ACME workflow for '", _domain, "'");
        return CompletionStatus.continue_;
    }

    void start_renewal()
    {
        writeInfo("Certificate '", name, "': certificate expires soon, starting renewal");
        _renewing = true;

        // Generate fresh ECDSA P-256 key for the new cert
        {
            auto r = generate_keypair(_renewal_keypair);
            if (!r)
            {
                writeWarningf("Certificate '{0}': renewal keygen failed, err={1,08x}", name, r.system_code);
                renewal_error("failed to generate renewal key pair");
                return;
            }
        }

        // Account key is already loaded (persists across renewals)
        if (_account_key.valid && !_account_pub_x.empty)
        {
            // Re-register challenge endpoint
            register_challenge_endpoint();

            // Create HTTP client for ACME API requests
            const(char)[] client_name = Collection!HTTPClient().generate_name(name[]);
            _acme_client = Collection!HTTPClient().create(
                client_name, ObjectFlags.dynamic,
                NamedArgument("remote", "https://acme-v02.api.letsencrypt.org"));

            if (!_acme_client)
            {
                renewal_error("failed to create ACME HTTP client");
                return;
            }

            _acme_state = AcmeState.need_directory;
            _request_pending = false;
            return;
        }

        // No account key — fall back to full start_acme via restart
        // (shouldn't happen if account was persisted, but be safe)
        writeWarning("Certificate '", name, "': no ACME account key for renewal, restarting");
        _renewing = false;
        _renewal_keypair.free_keypair();
        restart();
    }

    void renewal_error(const(char)[] msg)
    {
        writeWarning("Certificate '", name, "': renewal failed: ", msg);
        _acme_state = AcmeState.idle;
        _renewing = false;
        _renewal_keypair.free_keypair();
        destroy_acme_client();
        unregister_challenge_endpoint();

        ++_renewal_failures;
        // Exponential backoff: 1h, 2h, 4h, 8h, capped at 24h
        ulong backoff_hours = 1;
        for (uint i = 0; i < _renewal_failures - 1 && backoff_hours < 24; ++i)
            backoff_hours *= 2;
        if (backoff_hours > 24)
            backoff_hours = 24;
        _next_renewal_attempt = getTime() + dur!"hours"(backoff_hours);
        writeWarning("Certificate '", name, "': will retry renewal in ", backoff_hours, " hour(s)");
    }

    void update_acme()
    {
        if (_request_pending)
            return;

        if (!_acme_client || !_acme_client.running)
            return;

        final switch (_acme_state)
        {
            case AcmeState.idle:
                return;

            case AcmeState.need_directory:
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': GET /directory");
                _request_pending = true;
                _acme_client.request(HTTPMethod.GET, "/directory", &on_directory_response);
                return;

            case AcmeState.need_nonce:
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': HEAD ", _new_nonce_url);
                _request_pending = true;
                _acme_client.request(HTTPMethod.HEAD, _new_nonce_url[], &on_nonce_response);
                return;

            case AcmeState.need_account:
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': POST newAccount -> ", _new_account_url);
                acme_post(_new_account_url[],
                    "{\"termsOfServiceAgreed\":true}",
                    &on_account_response, true);
                return;

            case AcmeState.need_order:
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': POST newOrder -> ", _new_order_url, " domain='", _domain, "'");
                acme_post(_new_order_url[],
                    make_order_payload(),
                    &on_order_response, false);
                return;

            case AcmeState.need_authorization:
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': POST authz -> ", _acme_authz_url);
                acme_post(_acme_authz_url[],
                    "",
                    &on_authz_response, false);
                return;

            case AcmeState.challenge_pending:
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': POST challenge -> ", _acme_challenge_url);
                acme_post(_acme_challenge_url[],
                    "{}",
                    &on_challenge_response, false);
                return;

            case AcmeState.challenge_waiting:
                if (getTime() < _next_poll_time)
                    return;
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': polling authz -> ", _acme_authz_url);
                _next_poll_time = getTime() + 5.seconds;
                acme_post(_acme_authz_url[],
                    "",
                    &on_authz_poll_response, false);
                return;

            case AcmeState.need_finalize:
                auto csr_payload = make_finalize_payload();
                if (csr_payload is null)
                {
                    acme_error("CSR generation failed");
                    return;
                }
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': POST finalize -> ", _acme_finalize_url);
                acme_post(_acme_finalize_url[],
                    csr_payload,
                    &on_finalize_response, false);
                return;

            case AcmeState.cert_pending:
                if (getTime() < _next_poll_time)
                    return;
                version (DebugCertificate)
                    writeDebug("Certificate '", name, "': POST cert download -> ", _acme_cert_url);
                _next_poll_time = getTime() + 5.seconds;
                acme_post(_acme_cert_url[],
                    "",
                    &on_cert_response, false);
                return;
        }
    }

    void register_challenge_endpoint()
    {
        if (_challenge_registered)
            return;

        const(char)[] prefix = _uri.empty
            ? "/.well-known/acme-challenge/"
            : _uri[];

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': registering challenge endpoint prefix='", prefix, "'");

        _http_server.add_uri_handler(HTTPMethod.GET, prefix, &handle_acme_challenge);
        _challenge_registered = true;
    }

    void unregister_challenge_endpoint()
    {
        if (_challenge_registered && _http_server)
            _http_server.remove_uri_handler(HTTPMethod.GET, &handle_acme_challenge);
        _challenge_registered = false;
        _challenge_token = String.init;
        _challenge_auth = String.init;
    }

    void destroy_acme_client()
    {
        if (_acme_client)
        {
            _acme_client.destroy();
            _acme_client = null;
        }
    }

    void acme_error(const(char)[] msg)
    {
        if (_renewing)
        {
            renewal_error(msg);
            return;
        }
        writeError("Certificate '", name, "': ACME: ", msg);
        _status = CertStatus.error;
        _status_msg.concat("ACME error: ", msg);
        _acme_state = AcmeState.idle;
        destroy_acme_client();
    }

    const(char)[] extract_nonce(ref const HTTPMessage response)
    {
        return response.header("Replay-Nonce")[];
    }

    // --- ACME response handlers ---

    int on_directory_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': directory response status=", response.status_code);

        if (response.status_code != 200)
        {
            writeWarning("Certificate '", name, "': ACME directory response: ", cast(const(char)[])response.content[]);
            acme_error("directory fetch failed");
            return 0;
        }

        auto json = parse_json(cast(const(char)[])response.content[]);
        _new_nonce_url = json["newNonce"].asString().makeString(defaultAllocator());
        _new_account_url = json["newAccount"].asString().makeString(defaultAllocator());
        _new_order_url = json["newOrder"].asString().makeString(defaultAllocator());

        version (DebugCertificate)
        {
            writeDebug("Certificate '", name, "':   newNonce=", _new_nonce_url);
            writeDebug("Certificate '", name, "':   newAccount=", _new_account_url);
            writeDebug("Certificate '", name, "':   newOrder=", _new_order_url);
        }

        _acme_state = AcmeState.need_nonce;
        _status_msg.concat("ACME: authenticating");
        return 0;
    }

    int on_nonce_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': nonce response status=", response.status_code);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length == 0)
        {
            acme_error("no nonce in response");
            return 0;
        }
        _acme_nonce = nonce.makeString(defaultAllocator());
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': got nonce '", _acme_nonce, "'");

        if (!_acme_account_url.empty)
        {
            writeInfo("Certificate '", name, "': reusing cached account ", _acme_account_url);
            _acme_state = AcmeState.need_order;
            _status_msg.concat("ACME: ordering certificate");
        }
        else
            _acme_state = AcmeState.need_account;
        return 0;
    }

    int on_account_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': account response status=", response.status_code);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length > 0)
            _acme_nonce = nonce.makeString(defaultAllocator());

        if (response.status_code != 200 && response.status_code != 201)
        {
            writeWarning("Certificate '", name, "': ACME account response: ", cast(const(char)[])response.content[]);
            acme_error("account registration failed");
            return 0;
        }

        _acme_account_url = response.header("Location")[].makeString(defaultAllocator());
        if (_acme_account_url.empty)
        {
            acme_error("no Location header in account response");
            return 0;
        }

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': account URL=", _acme_account_url);
        writeInfo("Certificate '", name, "': ACME account registered");
        save_acme_account();
        _acme_state = AcmeState.need_order;
        _status_msg.concat("ACME: ordering certificate");
        return 0;
    }

    int on_order_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': order response status=", response.status_code);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length > 0)
            _acme_nonce = nonce.makeString(defaultAllocator());

        if (response.status_code == 429)
        {
            import urt.string : findFirst;
            auto body_text = cast(const(char)[])response.content[];
            writeWarning("Certificate '", name, "': ACME order response: ", body_text);
            // Extract "retry after YYYY-MM-DD HH:MM:SS UTC" from detail
            auto retry_pos = body_text.findFirst("retry after ");
            if (retry_pos < body_text.length)
            {
                auto retry_text = body_text[retry_pos + 12 .. $];
                auto end_pos = retry_text.findFirst('"');
                if (end_pos < retry_text.length)
                    retry_text = retry_text[0 .. end_pos];
                _status_msg.concat("rate limited, retry after ", retry_text);
            }
            else
                _status_msg.concat("rate limited by ACME server");
            _status = CertStatus.error;
            _acme_state = AcmeState.idle;
            destroy_acme_client();
            return 0;
        }

        if (response.status_code != 200 && response.status_code != 201)
        {
            writeWarning("Certificate '", name, "': ACME order response: ", cast(const(char)[])response.content[]);
            acme_error("order creation failed");
            return 0;
        }

        auto json = parse_json(cast(const(char)[])response.content[]);
        const(char)[] order_status = json["status"].asString();

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': order status='", order_status, "'");

        // Existing valid order — certificate already issued, just download it
        if (order_status == "valid")
        {
            _acme_cert_url = json["certificate"].asString().makeString(defaultAllocator());
            if (_acme_cert_url.empty)
            {
                acme_error("valid order has no certificate URL");
                return 0;
            }
            writeInfo("Certificate '", name, "': ACME order already valid, downloading certificate");
            _acme_state = AcmeState.cert_pending;
            _status_msg.concat("ACME: downloading certificate");
            return 0;
        }

        // Extract authorization URL (first one)
        auto authz_array = json["authorizations"];
        if (authz_array.length == 0)
        {
            acme_error("no authorizations in order");
            return 0;
        }
        _acme_authz_url = authz_array[0].asString().makeString(defaultAllocator());
        _acme_finalize_url = json["finalize"].asString().makeString(defaultAllocator());

        version (DebugCertificate)
        {
            writeDebug("Certificate '", name, "':   authz=", _acme_authz_url);
            writeDebug("Certificate '", name, "':   finalize=", _acme_finalize_url);
        }

        // Order is "ready" (authorizations already valid) — skip to finalize
        if (order_status == "ready")
        {
            writeInfo("Certificate '", name, "': ACME order ready, finalizing");
            _acme_state = AcmeState.need_finalize;
            _status_msg.concat("ACME: finalizing order");
            return 0;
        }

        writeInfo("Certificate '", name, "': ACME order created");
        _acme_state = AcmeState.need_authorization;
        _status_msg.concat("ACME: authorizing domain");
        return 0;
    }

    int on_authz_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': authz response status=", response.status_code);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length > 0)
            _acme_nonce = nonce.makeString(defaultAllocator());

        if (response.status_code != 200)
        {
            writeWarning("Certificate '", name, "': ACME authz response: ", cast(const(char)[])response.content[]);
            acme_error("authorization fetch failed");
            return 0;
        }

        auto json = parse_json(cast(const(char)[])response.content[]);
        auto challenges = json["challenges"];

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': ", challenges.length, " challenges in response");

        // Find HTTP-01 challenge
        for (uint i = 0; i < challenges.length; ++i)
        {
            auto c = challenges[i];
            version (DebugCertificate)
                writeDebug("Certificate '", name, "':   challenge[", i, "] type=", c["type"].asString());

            if (c["type"].asString() == "http-01")
            {
                _challenge_token = c["token"].asString().makeString(defaultAllocator());
                _acme_challenge_url = c["url"].asString().makeString(defaultAllocator());

                // Compute key authorization: token.thumbprint
                _challenge_auth = compute_key_authorization(_challenge_token[]);

                version (DebugCertificate)
                {
                    writeDebug("Certificate '", name, "':   token=", _challenge_token);
                    writeDebug("Certificate '", name, "':   challenge_url=", _acme_challenge_url);
                    writeDebug("Certificate '", name, "':   key_auth=", _challenge_auth);
                }
                writeInfo("Certificate '", name, "': ACME challenge token received, ready for validation");

                _acme_state = AcmeState.challenge_pending;
                _status_msg.concat("ACME: challenge pending");
                return 0;
            }
        }

        acme_error("no HTTP-01 challenge found");
        return 0;
    }

    int on_challenge_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': challenge response status=", response.status_code);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length > 0)
            _acme_nonce = nonce.makeString(defaultAllocator());

        if (response.status_code != 200)
        {
            writeWarning("Certificate '", name, "': ACME challenge response: ", cast(const(char)[])response.content[]);
            acme_error("challenge notification failed");
            return 0;
        }

        writeInfo("Certificate '", name, "': ACME challenge submitted, waiting for validation");
        _acme_state = AcmeState.challenge_waiting;
        _status_msg.concat("ACME: waiting for validation");
        return 0;
    }

    int on_authz_poll_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': authz poll response status=", response.status_code);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length > 0)
            _acme_nonce = nonce.makeString(defaultAllocator());

        if (response.status_code != 200)
        {
            writeWarning("Certificate '", name, "': ACME authz poll response: ", cast(const(char)[])response.content[]);
            acme_error("authorization poll failed");
            return 0;
        }

        auto json = parse_json(cast(const(char)[])response.content[]);
        const(char)[] auth_status = json["status"].asString();

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': authz poll status='", auth_status, "'");

        if (auth_status == "valid")
        {
            writeInfo("Certificate '", name, "': ACME challenge validated");
            _acme_state = AcmeState.need_finalize;
            _status_msg.concat("ACME: finalizing order");
        }
        else if (auth_status == "invalid")
        {
            writeWarning("Certificate '", name, "': ACME validation response: ", cast(const(char)[])response.content[]);
            acme_error("challenge validation failed");
        }
        // else still "pending" — will poll again next update cycle

        return 0;
    }

    int on_finalize_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': finalize response status=", response.status_code);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length > 0)
            _acme_nonce = nonce.makeString(defaultAllocator());

        if (response.status_code != 200)
        {
            writeWarning("Certificate '", name, "': ACME finalize response: ", cast(const(char)[])response.content[]);
            acme_error("finalize failed");
            return 0;
        }

        auto json = parse_json(cast(const(char)[])response.content[]);
        const(char)[] fin_status = json["status"].asString();

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': finalize status='", fin_status, "'");

        if (fin_status == "valid")
        {
            _acme_cert_url = json["certificate"].asString().makeString(defaultAllocator());
            version (DebugCertificate)
                writeDebug("Certificate '", name, "': cert URL=", _acme_cert_url);
            _acme_state = AcmeState.cert_pending;
            _status_msg.concat("ACME: downloading certificate");
        }
        else if (fin_status == "processing")
        {
            version (DebugCertificate)
                writeDebug("Certificate '", name, "': order still processing, will re-poll");
            // Order still processing, poll the order URL
            // The cert URL won't be available yet; stay in need_finalize
            // and the next poll will re-check
        }
        else
        {
            writeWarning("Certificate '", name, "': ACME finalize status '", fin_status, "': ", cast(const(char)[])response.content[]);
            acme_error("unexpected finalize status");
        }

        return 0;
    }

    int on_cert_response(ref const HTTPMessage response)
    {
        _request_pending = false;
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': cert response status=", response.status_code,
                " content_len=", cast(uint)response.content.length);

        const(char)[] nonce = extract_nonce(response);
        if (nonce.length > 0)
            _acme_nonce = nonce.makeString(defaultAllocator());

        if (response.status_code != 200)
        {
            writeWarning("Certificate '", name, "': ACME cert response: ", cast(const(char)[])response.content[]);
            acme_error("certificate download failed");
            return 0;
        }

        // Response body is the full PEM certificate chain
        CertRef new_cert;
        auto r = response.content[].load_certificate(new_cert);
        if (!r)
        {
            writeWarningf("Certificate '{0}': load issued cert failed, err={1,08x}", name, r.system_code);
            acme_error("failed to load issued certificate");
            return 0;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': certificate loaded from ACME response");

        // Associate the renewal keypair with the new cert
        r = new_cert.associate_key(_renewal_keypair);
        if (!r)
        {
            writeWarningf("Certificate '{0}': associate key failed, err={1,08x}", name, r.system_code);
            acme_error("failed to associate key with certificate");
            new_cert.free_cert();
            return 0;
        }

        // Promote: swap renewal keypair/cert into live state
        _certref.free_cert();
        _keypair.free_keypair();
        _certref = new_cert;
        _keypair = _renewal_keypair;
        _renewal_keypair = KeyPair.init;

        _expiry = _certref.cert_expiry();
        _status = CertStatus.issued;
        _status_msg.clear();
        _acme_state = AcmeState.idle;
        _renewing = false;
        _renewal_failures = 0;

        // Persist cert and key to disk for reuse across restarts
        save_acme_cert(response.content[]);

        unregister_challenge_endpoint();
        destroy_acme_client();
        if (_owns_http_server && _http_server)
        {
            _http_server.destroy();
            _http_server = null;
            _owns_http_server = false;
        }
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': ACME complete, context=", cast(ulong)_certref.native_cert_context());
        writeInfo("Certificate '", name, "': ACME certificate issued for '", _domain, "'");
        return 0;
    }

    // --- ACME JWS helpers ---

    /// POST a JWS-signed request to the ACME server.
    void acme_post(const(char)[] url, const(char)[] payload, HTTPMessageHandler handler, bool use_jwk)
    {
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': acme_post url=", url, " payload_len=", cast(uint)payload.length, " jwk=", use_jwk);

        if (_acme_nonce.empty)
        {
            version (DebugCertificate)
                writeDebug("Certificate '", name, "': no nonce, redirecting to need_nonce");
            _acme_state = AcmeState.need_nonce;
            return;
        }

        auto jws_body = build_jws(url, payload, use_jwk);
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': JWS body: ", jws_body[]);
        if (jws_body.empty)
        {
            acme_error("JWS construction failed");
            return;
        }

        // Extract resource path from full URL
        const(char)[] resource = url;
        size_t scheme = resource.findFirst("//");
        if (scheme != resource.length)
        {
            resource = resource[scheme + 2 .. $];
            size_t slash = resource.findFirst("/");
            if (slash != resource.length)
                resource = resource[slash .. $];
        }

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': POST resource=", resource, " body_len=", cast(uint)jws_body.length);

        HTTPParam[1] content_type_header = [
            HTTPParam(StringLit!"Content-Type", StringLit!"application/jose+json")
        ];
        _request_pending = true;
        _acme_client.request(HTTPMethod.POST, resource, handler,
            jws_body[], null, content_type_header);
    }

    /// Build a JWS (JSON Web Signature) body for ACME.
    Array!char build_jws(const(char)[] url, const(char)[] payload, bool use_jwk)
    {
        // Build protected header
        Array!char protected_header;
        protected_header.append("{\"alg\":\"ES256\"");
        if (use_jwk)
        {
            // First request uses JWK in header
            protected_header.append(",\"jwk\":", jwk_json());
        }
        else
        {
            // Subsequent requests use account URL (kid)
            protected_header.append(",\"kid\":\"", _acme_account_url[], "\"");
        }
        protected_header.append(",\"nonce\":\"", _acme_nonce[], "\"");
        protected_header.append(",\"url\":\"", url, "\"}");

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': JWS protected: ", protected_header[]);

        // Base64url encode header and payload
        auto b64_header = base64url(cast(ubyte[])protected_header[]);
        auto b64_payload = payload.length > 0
            ? base64url(cast(ubyte[])payload)
            : Array!char();

        // Signing input: base64url(header).base64url(payload)
        Array!char signing_input;
        signing_input.concat(b64_header[], ".", b64_payload[]);

        // SHA-256 hash the signing input, then sign with ECDSA
        SHA256Context sha_ctx;
        sha_init(sha_ctx);
        sha_update(sha_ctx, signing_input[]);
        auto hash = sha_finalise(sha_ctx);

        Array!ubyte signature;
        {
            auto r = _account_key.sign_hash(hash[], signature);
            if (!r)
            {
                version (DebugCertificate)
                    writeDebugf("Certificate '{0}': JWS sign_hash failed, err={1,08x}", name, r.system_code);
                return Array!char();
            }
        }

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': JWS signed, sig_len=", cast(uint)signature.length);

        auto b64_sig = base64url(signature[]);

        // Build final JWS JSON
        Array!char result;
        result.concat("{\"protected\":\"", b64_header[],
            "\",\"payload\":\"", b64_payload[],
            "\",\"signature\":\"", b64_sig[], "\"}");
        return result;
    }

    /// Build JWK JSON for the account key.
    Array!char jwk_json()
    {
        auto x_b64 = base64url(_account_pub_x[]);
        auto y_b64 = base64url(_account_pub_y[]);

        Array!char result;
        result.concat("{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"",
            x_b64[], "\",\"y\":\"", y_b64[], "\"}");
        return result;
    }

    /// Compute JWK thumbprint (SHA-256 of canonical JWK JSON).
    Array!char jwk_thumbprint()
    {
        auto jwk = jwk_json();

        SHA256Context sha_ctx;
        sha_init(sha_ctx);
        sha_update(sha_ctx, jwk[]);
        auto hash = sha_finalise(sha_ctx);

        return base64url(hash[]);
    }

    /// Compute key authorization: token.thumbprint
    String compute_key_authorization(const(char)[] token)
    {
        auto thumbprint = jwk_thumbprint();
        MutableString!0 result;
        result.concat(token, ".", thumbprint[]);
        return result[].makeString(defaultAllocator());
    }

    const(char)[] make_order_payload()
    {
        // TODO: use temp allocator for this
        static Array!char buf;
        buf.clear();
        buf.concat("{\"identifiers\":[{\"type\":\"dns\",\"value\":\"",
            _domain[], "\"}]}");
        return buf[];
    }

    const(char)[] make_finalize_payload()
    {
        // Generate CSR for the domain using the pending key
        auto csr = _renewal_keypair.generate_csr(_domain[]);
        if (csr.length == 0)
            return null;
        auto b64_csr = base64url(csr[]);

        static Array!char buf;
        buf.clear();
        buf.concat("{\"csr\":\"", b64_csr[], "\"}");
        return buf[];
    }

    int handle_acme_challenge(ref const HTTPMessage request, ref Stream stream, const(ubyte)[] leftover)
    {
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': challenge request path='", request.request_target, "'");

        if (!_challenge_registered || _challenge_token.empty)
        {
            HTTPMessage response = create_response(request.http_version, 404, StringLit!"Not Found",
                StringLit!"text/plain", "No pending challenge");
            stream.write(response.format_message()[]);
            return 0;
        }

        // Extract token from request path: /.well-known/acme-challenge/<token>
        const(char)[] path = request.request_target[];
        enum challenge_prefix = "/.well-known/acme-challenge/";
        if (!path.startsWith(challenge_prefix))
        {
            HTTPMessage response = create_response(request.http_version, 404, StringLit!"Not Found",
                StringLit!"text/plain", "Not found");
            stream.write(response.format_message()[]);
            return 0;
        }

        const(char)[] token = path[challenge_prefix.length .. $];
        if (token != _challenge_token[])
        {
            HTTPMessage response = create_response(request.http_version, 404, StringLit!"Not Found",
                StringLit!"text/plain", "Unknown token");
            stream.write(response.format_message()[]);
            return 0;
        }

        // Respond with key authorization: token.accountKeyThumbprint
        version (DebugCertificate)
            writeDebug("Certificate '", name, "': serving challenge auth=", _challenge_auth);
        writeInfo("Certificate '", name, "': serving ACME challenge response");
        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK",
            StringLit!"application/octet-stream", _challenge_auth[]);
        stream.write(response.format_message()[]);
        return 0;
    }

    /// Try loading a previously cached ACME cert + key from disk.
    /// Returns true if a valid, non-expired cert was loaded.
    bool try_load_cached_cert()
    {
        MutableString!0 cert_path, key_path;
        cert_path.concat("conf/cert/", name[], ".cert.pem");
        key_path.concat("conf/cert/", name[], ".key.pem");

        auto cert_data = cast(ubyte[])load_file(cert_path[]);
        if (cert_data is null)
            return false;

        auto key_data = cast(ubyte[])load_file(key_path[]);
        if (key_data is null)
        {
            defaultAllocator().free(cert_data);
            return false;
        }

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': found cached cert (", cast(uint)cert_data.length, "B) + key (", cast(uint)key_data.length, "B)");

        auto r = cert_data.load_certificate(_certref);
        if (!r)
        {
            writeWarningf("Certificate '{0}': cached certificate failed to load, err={1,08x}", name, r.system_code);
            defaultAllocator().free(cert_data);
            defaultAllocator().free(key_data);
            return false;
        }

        _expiry = _certref.cert_expiry();
        auto now = getSysTime();
        if (_expiry && _expiry < now)
        {
            writeWarning("Certificate '", name, "': cached certificate has expired, will re-issue");
            _certref.free_cert();
            defaultAllocator().free(cert_data);
            defaultAllocator().free(key_data);
            return false;
        }

        r = key_data.import_private_key(_keypair);
        if (!r)
        {
            writeWarningf("Certificate '{0}': cached private key failed to load, err={1,08x}", name, r.system_code);
            _certref.free_cert();
            defaultAllocator().free(cert_data);
            defaultAllocator().free(key_data);
            return false;
        }

        r = _certref.associate_key(_keypair);
        if (!r)
        {
            writeWarningf("Certificate '{0}': cached key/cert association failed, err={1,08x}", name, r.system_code);
            _certref.free_cert();
            _keypair.free_keypair();
            defaultAllocator().free(cert_data);
            defaultAllocator().free(key_data);
            return false;
        }

        defaultAllocator().free(cert_data);
        defaultAllocator().free(key_data);

        _status = CertStatus.issued;
        writeInfo("Certificate '", name, "': loaded cached ACME certificate (expires ", _expiry, ")");
        return true;
    }

    /// Save the issued ACME cert and private key to disk for reuse.
    void save_acme_cert(const(ubyte)[] cert_pem)
    {
        MutableString!0 cert_path, key_path;
        cert_path.concat("conf/cert/", name[], ".cert.pem");
        key_path.concat("conf/cert/", name[], ".key.pem");

        // Ensure conf/cert/ directory exists
        create_directory("conf/cert");

        // Save certificate PEM
        if (!save_file(cert_path[], cert_pem))
        {
            writeWarning("Certificate '", name, "': failed to save certificate to '", cert_path[], "'");
            return;
        }

        // Export and save private key as PEM
        Array!ubyte key_der;
        auto r = _keypair.export_private_key(key_der);
        if (!r)
        {
            writeWarningf("Certificate '{0}': failed to export private key, err={1,08x}", name, r.system_code);
            return;
        }

        auto key_pem = encode_pem(key_der[], "EC PRIVATE KEY");
        if (!save_file(key_path[], key_pem[]))
        {
            writeWarning("Certificate '", name, "': failed to save private key to '", key_path[], "'");
            return;
        }

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': saved cert (", cast(uint)cert_pem.length, "B) + key (", cast(uint)key_pem.length, "B) to conf/cert/");
        writeInfo("Certificate '", name, "': certificate and key saved to disk");
    }

    void save_acme_account()
    {
        create_directory("conf/cert");

        // Save account key
        Array!ubyte key_der;
        auto r = _account_key.export_private_key(key_der);
        if (!r)
        {
            writeWarningf("Certificate '{0}': failed to export ACME account key, err={1,08x}", name, r.system_code);
            return;
        }

        MutableString!0 key_path;
        key_path.concat("conf/cert/", name[], ".acme-account.key");
        if (!save_file(key_path[], key_der[]))
        {
            writeWarning("Certificate '", name, "': failed to save ACME account key");
            return;
        }

        // Save account URL
        MutableString!0 url_path;
        url_path.concat("conf/cert/", name[], ".acme-account.url");
        if (!save_file(url_path[], cast(const(ubyte)[])_acme_account_url[]))
        {
            writeWarning("Certificate '", name, "': failed to save ACME account URL");
            return;
        }

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': saved ACME account to conf/cert/");
    }

    bool try_load_acme_account()
    {
        MutableString!0 key_path, url_path;
        key_path.concat("conf/cert/", name[], ".acme-account.key");
        url_path.concat("conf/cert/", name[], ".acme-account.url");

        auto key_data = cast(ubyte[])load_file(key_path[]);
        if (key_data is null)
            return false;

        auto url_data = cast(char[])load_file(url_path[]);
        if (url_data is null)
        {
            defaultAllocator().free(key_data);
            return false;
        }

        auto r = key_data.import_private_key(_account_key);
        if (!r)
        {
            writeWarningf("Certificate '{0}': cached ACME account key failed to load, err={1,08x}", name, r.system_code);
            defaultAllocator().free(key_data);
            defaultAllocator().free(cast(ubyte[])url_data);
            return false;
        }

        _acme_account_url = url_data[0 .. url_data.length].makeString(defaultAllocator());

        defaultAllocator().free(key_data);
        defaultAllocator().free(cast(ubyte[])url_data);

        version (DebugCertificate)
            writeDebug("Certificate '", name, "': loaded ACME account key + URL=", _acme_account_url);
        return true;
    }

    void unload_cert()
    {
        _certref.free_cert();
        _keypair.free_keypair();
        _renewal_keypair.free_keypair();
        _account_key.free_keypair();
        destroy_acme_client();
        if (_owns_http_server && _http_server)
        {
            _http_server.destroy();
            _http_server = null;
            _owns_http_server = false;
        }
    }
}


private:

Array!char base64url(const(ubyte)[] data)
{
    size_t enc_len = base64url_encode_length(data.length);
    auto result = Array!char(Alloc, enc_len);
    urt.encoding.base64url_encode(data, result[0 .. enc_len]);
    return result;
}


class CertificateModule : Module
{
    mixin DeclareModule!"certificate";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!Certificate();
    }

    override void update()
    {
        Collection!Certificate().update_all();
    }
}
