module manager.secret;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.rand;
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

class Secret : BaseObject
{
    __gshared Property[3] Properties = [ Property.create!("password", password)(),
                                         Property.create!("algorithm", algorithm)(),
                                         Property.create!("services", services)() ];
nothrow @nogc:

    alias TypeName = StringLit!"secret";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!Secret, name.move, flags);
    }

    // Properties...
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

private:
    struct Service
    {
        bool enable;
        String profile;
    }

    HashFunction _function = HashFunction.plain_text; // TODO: not a great default! :P
    ubyte[16] _salt;
    Array!ubyte _hash;

    Array!ubyte _private_key; // for asymmetric keys (we should implement a secure keystore somehow...)

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
