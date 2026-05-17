module manager.secret;

import urt.array;
import urt.crypto.ecdh : ecdh_p256_compute_shared;
import urt.crypto.pki;
import urt.file : load_file, save_file;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.rand;
import urt.result;
import urt.string;

import manager.base;

nothrow @nogc:


enum HashFunction
{
    plain_text,
    sha1,
    sha256,
    // TODO: how about some real password KDF? Argon2id/scrypt/bcrypt?
}

enum SecretKind : ubyte
{
    password,
    ec_p256,
    // TODO: ec_p384, rsa_2048, x509_cert+key, api_token, ...
}

class Secret : BaseObject
{
    alias Properties = AliasSeq!(Prop!("kind", kind),
                                 Prop!("key_file", key_file),
                                 Prop!("password", password),
                                 Prop!("algorithm", algorithm),
                                 Prop!("services", services));
nothrow @nogc:

    enum type_name = "secret";
    enum path = "/secret";
    enum collection_id = CollectionType.secret;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Secret, id, flags);
    }

    // Properties...

    SecretKind kind() const pure
        => _kind;
    void kind(SecretKind value)
    {
        if (_kind == value)
            return;
        _kind = value;
        maybe_load_key();
    }

    ref const(String) key_file() const pure
        => _key_file;
    void key_file(String value)
    {
        if (value == _key_file)
            return;
        _key_file = value.move;
        maybe_load_key();
    }

    const(char)[] password() const pure
    {
        if (_function == HashFunction.plain_text)
            return cast(char[])_hash[];
        assert(false, "TODO: generate MCF string for hashed passwords?");
        // $algo$param$salt$hash
        return null;
    }
    void password(const(char)[] value)
    {
        set_password(cast(ubyte[])value, _function);
    }

    HashFunction algorithm() const pure
        => _function;
    void algorithm(HashFunction value)
    {
        if (_function == value)
            return;
        if (_function == HashFunction.plain_text)
        {
            // we can re-hash a plaintext password
            set_password(_hash[], value);
        }
        else
        {
            // the password we already store is not plaintext, we must discard it
            _function = value;
            _salt[] = 0;
            _hash = null;
        }
    }

    // should we return an array of strings instead of a comma-separated list?
    String services() const
    {
        MutableString!0 r;
        foreach (s; _services[])
        {
            if (s.value.enable)
                r.concat(r.length > 0 ? "," : "", s.key);
        }
        // TODO: we should be able to promote MutableString to String!!
        return r[].makeString(defaultAllocator());
    }
    void services(String[] value)
    {
        // this is awkward because we want to preserve the profile mappings...

        // first we'll disbale all services
        foreach (ref s; _services.values)
            s.enable = false;
        // now we'll enable or add the new ones
        foreach (ref s; value)
        {
            if (Service* srv = _services.get(s))
                srv.enable = true;
            else
                _services.insert(s, Service(true, String()));
        }
        // any left disabled with no profile override are junk, and we can clean them up
        foreach (ref s; _services.values)
        {
            if (!s.enable && !s.profile)
            {
                // TODO: remove this item...
                //       can our map remove while iterating?
            }
        }
    }
    void services(ref Array!String value)
        => services(value[]);


    // TODO: profile specification
    //       support: profile=def_profile,l2tp:l2tp_profile,ppp:ppp_profile,wifi:wifi_profile
//    ref inout(String[]) profile() inout pure
//    {
//        // TODO, what should we return? an array of strings? a single comma-separated string?
//    }
//    const(char)[] profile(String[] value)
//    {
//        assert(false, "TODO");
//    }


    // API...

    bool allow_service(const(char)[] service, String* profile = null) const
    {
        bool get_profile(const(Service)* service)
        {
            if (profile)
                *profile = service.profile ? service.profile : _def_profile;
            return true;
        }

        const(Service)* s = service in _services;
        if (s && s.enable)
            return get_profile(s);

        // macro services...

        // TODO: maybe "vpn" isn't really good; it's more like "tunnel"?
        s = "vpn" in _services;
        if (s && s.enable) switch (service)
        {
            case "ppp":
            case "pppoe":
            case "ipsec":
            case "sstp":
            case "l2tp":
            case "pptp":
            case "ovpn":
            case "wireguard":
            case "eoip":
            case "gre":
            case "ipip":
                return get_profile(s);
            default:
                return false;
        }

        s = "admin" in _services;
        if (s && s.enable) switch (service)
        {
            case "cli":
            case "webadmin": // TODO: what is better service name for webadmin?
            case "api":
                return get_profile(s);
            default:
                return false;
        }

        s = "any" in _services;
        if (s && s.enable)
            return get_profile(s);

        return false;
    }

    bool validate_password(const(char)[] password) const
    {
        if (_function == HashFunction.plain_text)
            return _hash[] == cast(ubyte[])password;
        Array!ubyte hash = hash_password(cast(ubyte[])password, _salt[], _function);
        return hash[] == _hash[];
    }


    // ---- ec_p256 API (only valid when kind == ec_p256 and key is loaded) ----

    // 64-byte uncompressed public point (X || Y), no leading 0x04.
    // Returns empty slice if the key isn't loaded.
    const(ubyte)[] public_key_raw() const pure
    {
        if (_kind != SecretKind.ec_p256 || !_pubkey_cached)
            return null;
        return _pubkey_xy[];
    }

    // Sign a hash (typically SHA-256). Output is DER-encoded ECDSA signature.
    Result sign_hash(const(ubyte)[] hash, out Array!ubyte signature)
    {
        if (_kind != SecretKind.ec_p256 || !_keypair.valid)
            return InternalResult.invalid_parameter;
        return .sign_hash(_keypair, hash, signature);
    }

    // Compute ECDH-P256 shared secret with peer_xy (64-byte uncompressed point).
    // Writes 32 bytes of the shared X coordinate into shared_x.
    Result ecdh_compute_shared(const(ubyte)[] peer_xy, ubyte[] shared_x)
    {
        if (_kind != SecretKind.ec_p256 || !_keypair.valid || !_pubkey_cached)
            return InternalResult.invalid_parameter;
        return ecdh_p256_compute_shared(_privkey_d[], _pubkey_xy[], peer_xy, shared_x);
    }

private:
    struct Service
    {
        bool enable;
        String profile;
    }

    SecretKind _kind = SecretKind.password;

    // ---- password storage ----
    HashFunction _function = HashFunction.plain_text; // TODO: not a great default! :P
    ubyte[16] _salt;
    Array!ubyte _hash;

    // ---- ec_p256 storage ----
    KeyPair _keypair;
    ubyte[32] _privkey_d;
    ubyte[64] _pubkey_xy;
    bool _pubkey_cached;

    String _key_file;

    Map!(String, Service) _services;
    String _def_profile;

    void set_password(ubyte[] password, HashFunction hash_function)
    {
        if (hash_function == HashFunction.plain_text)
            _salt[] = 0;
        else
        {
            for (size_t i = 0; i < 16; i += uint.sizeof)
                *cast(uint*)&_salt[i] = rand();
        }
        _function = hash_function;
        _hash = hash_password(password, _salt[], hash_function);
    }

    void maybe_load_key()
    {
        if (_kind != SecretKind.ec_p256 || _key_file.empty)
            return;

        if (_keypair.valid)
            free_keypair(_keypair);
        _pubkey_cached = false;

        void[] file = load_file(_key_file[], defaultAllocator());
        if (file)
        {
            scope(exit) defaultAllocator.free(file);
            Result r = import_private_key(cast(const(ubyte)[])file, _keypair);
            if (r.failed)
            {
                log.warning("failed to load EC key from '", _key_file[], "': ", r.system_code);
                return;
            }
        }
        else
        {
            Result r = generate_keypair(_keypair);
            if (r.failed)
            {
                log.warning("failed to generate EC keypair: ", r.system_code);
                return;
            }
            Array!ubyte exported;
            r = export_private_key(_keypair, exported);
            if (r.failed)
            {
                log.warning("failed to export newly-generated EC key: ", r.system_code);
                free_keypair(_keypair);
                return;
            }
            r = save_file(_key_file[], exported[]);
            if (r.failed)
            {
                log.warning("failed to save EC key to '", _key_file[], "': ", r.system_code);
                // keep the keypair in memory anyway so the install can keep working until the user fixes the path
                // ...next restart will re-generate.
            }
        }

        Array!ubyte x, y;
        Result r = export_public_key_raw(_keypair, x, y);
        if (r.failed || x.length != 32 || y.length != 32)
        {
            log.warning("failed to export public key components");
            free_keypair(_keypair);
            return;
        }
        _pubkey_xy[0 .. 32] = x[];
        _pubkey_xy[32 .. 64] = y[];

        ubyte[32] d = void;
        r = export_private_scalar(_keypair, d);
        if (r.succeeded)
            _privkey_d[] = d[];

        _pubkey_cached = true;
    }
}


Array!ubyte hash_password(const ubyte[] password, const ubyte[] salt, HashFunction hash_function)
{
    import urt.digest.sha;

    Array!ubyte hash;
    switch (hash_function)
    {
        case HashFunction.plain_text:
            hash = password[];
            break;

        case HashFunction.sha1:
            SHA1Context ctx;
            sha_init(ctx);
            sha_update(ctx, salt[]);
            sha_update(ctx, password[]);
            hash = sha_finalise(ctx);
            break;

        case HashFunction.sha256:
            SHA256Context ctx;
            sha_init(ctx);
            sha_update(ctx, salt[]);
            sha_update(ctx, password[]);
            hash = sha_finalise(ctx);
            break;

        default:
            assert(false, "Unsupported hash function");
    }
    return hash;
}
