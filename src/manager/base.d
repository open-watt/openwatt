module manager.base;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.meta;
import urt.mem.string;
import urt.mem.temp;
import urt.variant;
import urt.string;

public import manager.collection : collectionTypeInfo, CollectionTypeInfo;

nothrow @nogc:


enum ClientStateSignal
{
    Destroyed,
    Online,
    Offline
}

struct Property
{
    alias GetFun = Variant function(BaseObject i) nothrow @nogc;
    alias SetFun = const(char)[] function(ref const Variant value, BaseObject i) nothrow @nogc;
    alias ResetFun = void function(BaseObject i) nothrow @nogc;
    alias SuggestFun = Array!String function(const(char)[] arg) nothrow @nogc;

    String name;
    GetFun get;
    SetFun set;
    ResetFun reset;
    SuggestFun suggest;

    static Property create(string name, alias member)()
    {
        import manager.console.argument;

        enum Member = __traits(identifier, member);

        alias Type = __traits(parent, member);
        static assert(is(Type : BaseObject), "Type must be a subclass of BaseObject");

        Property prop;
        prop.name = StringLit!name;

        static foreach (i; 0 .. __traits(getOverloads, Type, Member).length)
        {{
            alias Fun = typeof(&__traits(getOverloads, Type, Member)[i]);
            static if (is(Fun == R function(Args) nothrow @nogc, R, Args...))
            {
                static if (Args.length == 0)
                {
                    prop.get = (BaseObject item) {
                        Type instance = cast(Type)item;
                        auto r = __traits(getOverloads, instance, Member)[i]();
                        assert(false, "TODO: convert to Variant...");
                        return Variant(/+...+/);
                    };
                }
                else static if (Args.length == 1)
                {
                    prop.set = (ref const Variant value, BaseObject item) {
                        Type instance = cast(Type)item;
                        Args[0] arg;
                        if (const(char)[] error = convertVariant(value, arg))
                            return error;
                        static if (is(R == void))
                        {
                            __traits(getOverloads, instance, Member)[i](arg);
                            return null;
                        }
                        else
                            return __traits(getOverloads, instance, Member)[i](arg);
                    };

                    static if (is(typeof(suggestCompletion!(Args[0]))))
                        prop.suggest = &suggestCompletion!(Args[0]);
                }
                else
                {
                    static assert(false, "it's something else! - ", Fun.stringof);
                }
            }
        }}

        return prop;
    }
}


class BaseObject
{
    __gshared Property[5] Properties = [ Property.create!("type", type)(),
                                         Property.create!("name", name)(),
                                         Property.create!("disabled", disabled)(),
                                         Property.create!("comment", comment)(),
                                         Property.create!("status", statusMessage)() ];
nothrow @nogc:

    // TODO: delete this constructor!!!
    this(String name, const(char)[] type)
    {
        _typeInfo = null;
        _type = type.addString();
        _name = name.move;
    }

    this(const CollectionTypeInfo* typeInfo, String name)
    {
        _typeInfo = typeInfo;
        _type = typeInfo.type[].addString();
        _name = name.move;
    }


    // Properties...

    final const(char)[] type() const pure
        => _type;

    final ref const(String) name() const pure
        => _name;
    final const(char)[] name(ref String value)
    {
        // TODO: check if name is already in use...
        _name = value.move;
        return null;
    }

    final ref const(String) comment() const pure
        => _comment;
    final void comment(ref String value)
    {
        _comment = value.move;
    }

    final bool disabled() const pure
        => _disabled;
    final void disabled(bool value)
    {
        enable(!value);
    }

    // give a helpful status string, e.g. "Ready", "Disabled", "Error: <message>"
    const(char)[] statusMessage() const pure
        => disabled ? "Disabled" : validate() ? "Invalid" : "Ready";


    // Implement for derived types

    // per-tick updates
    void update()
    {
    }

    // validate configuration is in an operable state, update status if it's not
    bool validate() const pure
        => true;

    // enable/disable methods; returns prior state before the call
    abstract bool enable(bool enable = true);

    final bool disable()
        => enable(false);

    final bool restart()
    {
        bool wasEnabled = !_disabled;
        if (wasEnabled)
            enable(false);
        enable(true);
        return wasEnabled;
    }


    // Object API...

    // return a list of properties that can be set on this object
    final const(Property*)[] properties() const
        => _typeInfo.properties;

    // get and set and reset (to default) properties
    final Variant get(scope const(char)[] property)
    {
        foreach (p; properties())
        {
            if (p.name[] == property)
            {
                // some properties aren't get-able...
                if (p.get)
                    return p.get(this);
                return Variant();
            }
        }
        // TODO: should we return empty if the property doesn't exist; or should we complain somehow?
        return Variant();
    }

    final const(char)[] set(scope const(char)[] property, ref const Variant value)
    {
        foreach (i, p; properties())
        {
            if (p.name[] == property)
            {
                if (!p.set)
                    return tconcat("Property '", property, "' is read-only");
                return p.set(value, this);
            }
        }
        return tconcat("No property '", property, "' for ", name[]);
    }

    final void reset(scope const(char)[] property)
    {
        foreach (i, p; properties())
        {
            if (p.name[] == property)
            {
                propsSet &= ~(1 << i);
                if (p.reset)
                    p.reset(this);
                return;
            }
        }
    }

    // get the whole config
    final Variant getConfig() const
        => Variant();

    final MutableString!0 exportConfig() const pure
    {
        // TODO: this should return a string that contains the command which would recreate this object...
        return MutableString!0();
    }

    final void registerClient(BaseObject client)
    {
        assert(!clients[].exists(client), "Client already registered");
        clients ~= client;
    }

protected:
    const CollectionTypeInfo* _typeInfo;
    size_t propsSet;
    bool _disabled; // TODO: this unaligns the whole thing... maybe steal the top bit of propsSet?

    // sends a signal to all clients
    void signalStateChange(ClientStateSignal signal)
    {
        foreach (c; clients)
            c.clientSignal(this, signal);
    }

    // receive signal from a subscriber
    void clientSignal(BaseObject client, ClientStateSignal signal)
    {
        debug assert(clients[].exists(client), "Client not registered!");

        if (signal == ClientStateSignal.Destroyed)
            clients.removeFirstSwapLast(client);
    }

private:
    const CacheString _type; // TODO: DELETE THIS MEMBER!!!
    String _name;
    String _comment;
    Array!BaseObject clients;
}


const(Property*)[] allProperties(Type)()
{
    alias AllProps = allPropertiesImpl!(Type, 0);
    enum Count = typeof(AllProps()).length;
    __gshared const(Property*)[Count] props = AllProps();
    return props[];
}


private:

auto allPropertiesImpl(Type, size_t allocCount)()
{
    import urt.traits : Unqual;

    static if (is(Type S == super) && !is(Unqual!S == Object))
    {
        alias Super = Unqual!S;
        static if (!is(typeof(Type.Properties) == typeof(Super.Properties)) || &Type.Properties !is &Super.Properties)
            enum PropCount = Type.Properties.length;
        else
            enum PropCount = 0;
        auto result = allPropertiesImpl!(Super, PropCount + allocCount)();
    }
    else
    {
        enum PropCount = Type.Properties.length;
        const(Property)*[PropCount + allocCount] result;
    }

    static foreach (i; 0 .. PropCount)
        result[result.length - allocCount - PropCount + i] = &Type.Properties[i];
    return result;
}
