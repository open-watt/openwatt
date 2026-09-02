module manager.secret;

import urt.array;
import urt.crypto.ecdh : ecdh_p256_compute_shared;
import urt.crypto.pki;
import urt.file : file_exists, load_file, save_file;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.rand;
import urt.result;
import urt.string;

import manager.base;
import manager.features;

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
nothrow @nogc:

    enum type_name = "secret";
    enum path = "/secret";
    enum collection_id = CollectionType.secret;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Secret, id, flags);
    }

    ~this()
    {
        static if (has_ec_secret)
            clear_key();
    }

    // Properties...

    SecretKind kind() const pure
        => _kind;
    void kind(SecretKind value)
    {
        if (_kind != value)
        {
            static if (has_ec_secret)
                if (_kind == SecretKind.ec_p256)
                    clear_key();
            _kind = value;
            static if (has_ec_secret)
                maybe_load_key();
        }
        mark_set!(typeof(this), "kind")();
    }

    static if (has_ec_secret)
    ref const(String) key_file() const pure
        => _key_file;
    static if (has_ec_secret)
    void key_file(String value)
    {
        if (value != _key_file)
        {
            _key_file = value.move;
            if (_key_file.empty)
                clear_key();
            else
                maybe_load_key();
        }
        mark_set!(typeof(this), "key_file")();
    }

    static if (has_ec_secret)
        alias Properties = AliasSeq!(Prop!("kind", kind),
                                     Prop!("key_file", key_file),
                                     Prop!("password", password),
                                     Prop!("algorithm", algorithm),
                                     Prop!("services", services));
    else
        alias Properties = AliasSeq!(Prop!("kind", kind),
                                     Prop!("password", password),
                                     Prop!("algorithm", algorithm),
                                     Prop!("services", services));

    const(char)[] password() const
    {
        if (_function == HashFunction.plain_text)
            return cast(char[])_hash[];
        if (_hash.empty)
            return null;

        import urt.mem.temp : talloc;
        import urt.string.ascii : hex_digits;

        // colon-separated rather than MCF '$' form: '$' triggers interpolation in the console lexer
        const(char)[] algo = hash_function_name(_function);
        char[] buf = cast(char[])talloc(7 + algo.length + _salt.length*2 + _hash.length*2);
        size_t o = 0;
        buf[o .. o + 5] = "hash:"; o += 5;
        buf[o .. o + algo.length] = algo[]; o += algo.length;
        buf[o++] = ':';
        foreach (b; _salt[])
        {
            buf[o++] = hex_digits[b >> 4];
            buf[o++] = hex_digits[b & 0xF];
        }
        buf[o++] = ':';
        foreach (b; _hash[])
        {
            buf[o++] = hex_digits[b >> 4];
            buf[o++] = hex_digits[b & 0xF];
        }
        return buf[0 .. o];
    }
    void password(const(char)[] value)
    {
        if (try_set_mcf(value))
            return;
        set_password(cast(ubyte[])value, _function);
    }

    // recoverable secret material for outbound use (wifi psk etc); empty when only the hash is known
    const(char)[] plaintext() const pure
    {
        if (_function == HashFunction.plain_text)
            return cast(const(char)[])_hash[];
        return cast(const(char)[])_plaintext[];
    }

    HashFunction algorithm() const pure
        => _function;
    void algorithm(HashFunction value)
    {
        if (_function == value)
        {
            mark_set!(typeof(this), "algorithm")();
            return;
        }
        if (_function == HashFunction.plain_text)
        {
            // we can re-hash a plaintext password
            set_password(_hash[], value);
        }
        else if (!_plaintext.empty)
        {
            Array!ubyte keep = _plaintext[];
            set_password(keep[], value);
        }
        else
        {
            // the stored password is not plaintext and not recoverable, we must discard it
            _function = value;
            _salt[] = 0;
            _hash = null;
            mark_set!(typeof(this), [ "algorithm", "password" ])();
        }
    }

    const(char)[][] services() const
    {
        import urt.mem.temp : talloc_array;

        auto buf = talloc_array!(const(char)[])(_services.length);
        size_t n = 0;
        foreach (s; _services[])
        {
            if (s.value.enable)
                buf[n++] = s.key[];
        }
        return buf[0 .. n];
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
        mark_set!(typeof(this), "services")();
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


    override bool validate() const
    {
        static if (has_ec_secret)
            return _kind != SecretKind.ec_p256 || !_key_file.empty;
        else
            return _kind != SecretKind.ec_p256;
    }


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

    // 64-byte uncompressed public point (X || Y), no leading 0x04.
    // Returns empty slice if the key isn't loaded.
    static if (has_ec_secret)
    const(ubyte)[] public_key_raw() const pure
    {
        if (_kind != SecretKind.ec_p256 || !_pubkey_cached)
            return null;
        return _pubkey_xy[];
    }

    // Sign a hash (typically SHA-256). Output is DER-encoded ECDSA signature.
    static if (has_ec_secret)
    Result sign_hash(const(ubyte)[] hash, out Array!ubyte signature)
    {
        if (_kind != SecretKind.ec_p256 || !_keypair.valid)
            return InternalResult.invalid_parameter;
        return .sign_hash(_keypair, hash, signature);
    }

    // Compute ECDH-P256 shared secret with peer_xy (64-byte uncompressed point).
    // Writes 32 bytes of the shared X coordinate into shared_x.
    static if (has_ec_secret)
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

    HashFunction _function = HashFunction.plain_text; // TODO: not a great default! :P
    ubyte[16] _salt;
    Array!ubyte _hash;
    Array!ubyte _plaintext;     // retained for outbound use; persisted in the side store, never in config

    static if (has_ec_secret)
    {
        KeyPair _keypair;
        ubyte[32] _privkey_d;
        ubyte[64] _pubkey_xy;
        bool _pubkey_cached;
    }

    static if (has_ec_secret)
        String _key_file;

    Map!(String, Service) _services;
    String _def_profile;

    void set_password(ubyte[] password, HashFunction hash_function)
    {
        if (hash_function == HashFunction.plain_text)
        {
            _salt[] = 0;
            _plaintext = null;
        }
        else
        {
            for (size_t i = 0; i < 16; i += uint.sizeof)
                *cast(uint*)&_salt[i] = rand();
            // copy before _hash is replaced: the re-hash path passes a slice of the old _hash
            Array!ubyte keep = password[];
            _plaintext = keep.move;
        }
        _function = hash_function;
        _hash = hash_password(password, _salt[], hash_function);
        if (hash_function != HashFunction.plain_text)
            store_secret_material(_hash[], _plaintext[]);
        mark_set!(typeof(this), [ "password", "algorithm" ])();
    }

    // accepts the hash:algo:salt:hash form the password getter emits, so exports reload
    bool try_set_mcf(const(char)[] value)
    {
        if (value.length < 6 || value[0 .. 5] != "hash:")
            return false;
        const(char)[] rest = value[5 .. $];
        size_t sep = 0;
        while (sep < rest.length && rest[sep] != ':')
            ++sep;
        if (sep == rest.length)
            return false;

        HashFunction fn;
        if (rest[0 .. sep] == hash_function_name(HashFunction.sha1))
            fn = HashFunction.sha1;
        else if (rest[0 .. sep] == hash_function_name(HashFunction.sha256))
            fn = HashFunction.sha256;
        else
            return false;

        rest = rest[sep + 1 .. $];
        sep = 0;
        while (sep < rest.length && rest[sep] != ':')
            ++sep;
        if (sep != _salt.length*2 || rest.length <= sep + 1)
            return false;

        ubyte[16] salt;
        Array!ubyte hash;
        hash.resize((rest.length - sep - 1) / 2);
        if (!parse_hex_bytes(rest[0 .. sep], salt[]) || !parse_hex_bytes(rest[sep + 1 .. $], hash[]))
            return false;

        _function = fn;
        _salt = salt;
        _hash = hash.move;
        _plaintext = lookup_secret_material(_hash[]);
        mark_set!(typeof(this), [ "password", "algorithm" ])();
        return true;
    }

    static if (has_ec_secret)
    void maybe_load_key()
    {
        if (_kind != SecretKind.ec_p256 || _key_file.empty)
            return;

        clear_key();

        // a key file that exists but can't be read must not be overwritten; that would discard an enrolled identity
        if (file_exists(_key_file[]))
        {
            void[] file = load_file(_key_file[]);
            if (!file)
            {
                log.error("failed to read EC key file '", _key_file[], "'");
                return;
            }
            scope(exit)
            {
                secure_zero(cast(ubyte[])file);
                free(file);
            }
            Result r = import_private_key(cast(const(ubyte)[])file, _keypair);
            if (r.failed)
            {
                log.error("failed to load EC key from '", _key_file[], "': ", r.system_code);
                return;
            }
        }
        else
        {
            Result r = generate_keypair(_keypair);
            if (r.failed)
            {
                log.error("failed to generate EC keypair: ", r.system_code);
                return;
            }
            Array!ubyte exported;
            r = export_private_key(_keypair, exported);
            if (r.failed)
            {
                log.error("failed to export newly-generated EC key: ", r.system_code);
                free_keypair(_keypair);
                return;
            }
            r = save_file(_key_file[], exported[]);
            secure_zero(exported[]);
            if (r.failed)
            {
                log.warning("failed to save EC key to '", _key_file[], "': ", r.system_code);
                // keep the keypair so this run can work; next restart will re-generate
            }
        }

        Array!ubyte x, y;
        Result r = export_public_key_raw(_keypair, x, y);
        if (r.failed || x.length != 32 || y.length != 32)
        {
            log.error("failed to export public key components");
            free_keypair(_keypair);
            return;
        }
        _pubkey_xy[0 .. 32] = x[];
        _pubkey_xy[32 .. 64] = y[];

        ubyte[32] d = void;
        scope(exit) secure_zero(d[]);
        r = export_private_scalar(_keypair, d);
        if (r.failed)
        {
            log.error("failed to export private key scalar");
            free_keypair(_keypair);
            return;
        }
        _privkey_d[] = d[];

        _pubkey_cached = true;
    }

    static if (has_ec_secret)
    void clear_key()
    {
        if (_keypair.valid)
            free_keypair(_keypair);
        secure_zero(_privkey_d[]);
        _pubkey_xy[] = 0;
        _pubkey_cached = false;
    }
}


// Wipe key material. The volatile store keeps the optimiser from eliding a
// write to memory that is never read again, which a plain slice assignment
// permits.
void secure_zero(ubyte[] buffer)
{
    import core.volatile : volatileStore;

    foreach (ref b; buffer)
        volatileStore(&b, ubyte(0));
}


// hash -> plaintext side store: lets hashed exports stay usable for outbound secrets.
// Lives beside the config, is never exported or synced, and losing it only costs
// outbound use until someone re-types the password.
enum secret_store_file = "conf/secret.store";

Array!ubyte lookup_secret_material(const(ubyte)[] hash)
{
    load_secret_store();
    String key = tconcat_hex(hash).make_string();
    if (Array!ubyte* p = key in g_secret_store)
    {
        Array!ubyte r = (*p)[];
        return r.move;
    }
    return Array!ubyte();
}

void store_secret_material(const(ubyte)[] hash, const(ubyte)[] plain)
{
    load_secret_store();
    String key = tconcat_hex(hash).make_string();
    if (Array!ubyte* p = key in g_secret_store)
    {
        if ((*p)[] == plain[])
            return;
        *p = plain[];
    }
    else
    {
        Array!ubyte v = plain[];
        g_secret_store.insert(key.move, v.move);
    }
    write_secret_store();
}

private:

__gshared Map!(String, Array!ubyte) g_secret_store;
__gshared bool g_secret_store_loaded;

const(char)[] tconcat_hex(const(ubyte)[] bytes)
{
    import urt.mem.temp : talloc;
    import urt.string.ascii : hex_digits;

    char[] buf = cast(char[])talloc(bytes.length*2);
    foreach (i, b; bytes)
    {
        buf[i*2] = hex_digits[b >> 4];
        buf[i*2 + 1] = hex_digits[b & 0xF];
    }
    return buf;
}

void load_secret_store()
{
    if (g_secret_store_loaded)
        return;
    g_secret_store_loaded = true;

    char[] data = cast(char[])load_file(secret_store_file);
    if (data is null)
        return;

    const(char)[] text = data;
    while (!text.empty)
    {
        const(char)[] line = text.split!'\n';
        if (line.empty)
            continue;
        const(char)[] key = line.split!':';
        if (key.empty || line.empty || (line.length & 1))
            continue;
        Array!ubyte plain;
        plain.resize(line.length / 2);
        if (!parse_hex_bytes(line, plain[]))
            continue;
        g_secret_store.insert(key.make_string(), plain.move);
    }
    free(cast(void[])data);
}

void write_secret_store()
{
    import urt.string.ascii : hex_digits;

    MutableString!0 buf;
    foreach (ref kvp; g_secret_store[])
    {
        buf.append(kvp.key[], ':');
        foreach (b; kvp.value[])
            buf.append(hex_digits[b >> 4], hex_digits[b & 0xF]);
        buf.append('\n');
    }
    if (!save_file(secret_store_file, cast(const(void)[])buf[]))
        log_warning("secret", "could not write '", secret_store_file, "'");
}

const(char)[] hash_function_name(HashFunction fn) pure
{
    final switch (fn)
    {
        case HashFunction.plain_text: return "plain";
        case HashFunction.sha1:       return "sha1";
        case HashFunction.sha256:     return "sha256";
    }
}

bool parse_hex_bytes(const(char)[] text, ubyte[] bytes) pure
{
    if (text.length != bytes.length*2)
        return false;
    foreach (i, ref b; bytes)
    {
        int hi = hex_value(text[i*2]);
        int lo = hex_value(text[i*2 + 1]);
        if (hi < 0 || lo < 0)
            return false;
        b = cast(ubyte)((hi << 4) | lo);
    }
    return true;
}

private int hex_value(char c) pure
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
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
