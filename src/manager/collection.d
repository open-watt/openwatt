module manager.collection;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.result;
import urt.string;

public import manager.base;
public import manager.expression : NamedArgument;

nothrow @nogc:


const(CollectionTypeInfo)* collection_type_info(Type)() nothrow @nogc
{
    static if (!is(typeof(Type.TypeName)))
        return null; // Type.TypeName must be defined
    else
    {
        import urt.mem.allocator;
        __gshared const CollectionTypeInfo ti = CollectionTypeInfo(Type.TypeName,
                                                                   all_properties!Type(),
                                                                   (){
                                                                        static if (is(typeof(Type.validate_name) == function))
                                                                            return &Type.validate_name;
                                                                        else
                                                                            return null;
                                                                   }(),
                                                                   (ref BaseCollection c, const(char)[] n, ObjectFlags flags)
                                                                       => defaultAllocator.allocT!Type((n ? n : c.generate_name(Type.TypeName[])).makeString(defaultAllocator), flags)
                                                                   );
        return &ti;
    }
}

ref Collection!Type* collection_for(Type)() nothrow @nogc
{
    __gshared Collection!Type* collection;
    return collection;
}

struct CollectionTypeInfo
{
    alias ValidateName = const(char)[] function(const(char)[] name) nothrow @nogc;
    alias CreateFun = BaseObject function(ref BaseCollection collection, const(char)[] name, ObjectFlags flags = ObjectFlags.none) nothrow @nogc;

    String type;
    const(Property*)[] properties;
    ValidateName validate_name;
    CreateFun create;
}

struct BaseCollection
{
nothrow @nogc:
    const CollectionTypeInfo* type_info;
    Map!(String, BaseObject) pool;

    this(const CollectionTypeInfo* type_info)
    {
        this.type_info = type_info;
    }

    BaseObject create(const(char)[] name, ObjectFlags flags = ObjectFlags.none, in NamedArgument[] named_args...)
    {
        assert(type_info, "Can't create into a base collection!");

        if (exists(name))
            return null;
        if (type_info.validate_name && type_info.validate_name(name) != null)
            return null;

        BaseObject item = alloc(name, flags);

        foreach (ref arg; named_args)
        {
            StringResult result = item.set(arg.name, arg.value);
            if (!result)
            {
                defaultAllocator.freeT(item);
                return null;
            }
        }

        add(item);
        return item;
    }

    BaseObject alloc(const(char)[] name, ObjectFlags flags = ObjectFlags.none)
    {
        assert(type_info, "Can't create into a base collection!");
        return type_info.create(this, name, flags);
    }

    auto keys() const
        => pool.keys;
    auto values()
        => pool.values;
//    auto values() const
//        => pool.values;
    auto opIndex()
        => pool[];
//    auto opIndex() const
//        => pool[];

    void update_all()
    {
        Array!BaseObject doomed;
        foreach (item; pool.values)
        {
            if (item.do_update())
                doomed ~= item;
        }
        foreach (item; doomed)
        {
            import urt.mem;
            remove(item);
            defaultAllocator.freeT(item);
        }
    }

    void add(BaseObject item)
    {
        assert(item.name[] !in pool, "Already exists");
        pool.insert(item.name, item);
    }

    void remove(BaseObject item)
    {
        assert(item.name[] in pool, "Not found");
        pool.remove(item.name);
    }

    inout(BaseObject)* exists(const(char)[] name) inout pure
        => name in pool;

    final inout(BaseObject) get(const(char)[] name) inout pure
    {
        inout(BaseObject)* item = name in pool;
        return item ? *item : null;
    }

    const(char)[] generate_name(const(char)[] prefix)
    {
        import urt.mem.temp : tconcat;

        assert(prefix !is null);

        if (prefix !in pool)
            return prefix;
        for (size_t i = 1; i < ushort.max; i++)
        {
            const(char)[] name = tconcat(prefix, i);
            if (name !in pool)
                return name;
        }
        return null;
    }
}

struct Collection(Type)
{
nothrow @nogc:
    static assert(is(Type : BaseObject), "Type must be a subclass of BaseObject");

    BaseCollection _base = BaseCollection(collection_type_info!Type);
    alias _base this;

    Type create(const(char)[] name, ObjectFlags flags = ObjectFlags.none, in NamedArgument[] named_args...)
        => cast(Type)_base.create(name, flags, named_args);

    Type alloc(const(char)[] name, ObjectFlags flags = ObjectFlags.none)
        => cast(Type)_base.alloc(name, flags);

    void add(Type item)
    {
        assert(item.name[] !in pool, "Already exists");
        pool.insert(item.name, item);
    }

    inout(Type)* exists(const(char)[] name) inout pure
        => cast(inout(Type)*)_base.exists(name);

    Type get(const(char)[] name)
        => cast(Type)_base.get(name);

    auto values()
    {
        struct Range
        {
            typeof(_base.values()) r;

            bool empty() const pure
                => r.empty;
            auto front() pure
                => cast(Type)r.front;
//            auto front() const pure
//                => cast(const Type)r.front;
            void popFront()
                => r.popFront();
        }
        return Range(_base.values);
    }
//    auto values() const
//    {
//        struct Range
//        {
//            typeof((cast(const)_base).values()) r;
//
//            bool empty() const pure
//                => r.empty;
//            auto front() const pure
//                => cast(const Type)r.front;
//            void popFront()
//                => r.popFront();
//        }
//        return Range(_base.values);
//    }

    auto opIndex()
    {
        struct Range
        {
            typeof(_base.opIndex()) r;

            bool empty() const pure
                => r.empty;
            auto front()
            {
//                import urt.meta.tuple;
//                return tuple(r.front()[0], cast(Type)r.front()[1]);
                struct KV
                {
                    const String* s;
                    ref const(String) key() @property const pure
                        => *s;
                    Type value;
                }
                return KV(&r.front.key(), cast(Type)r.front.value); // we shouldn't dynamic cast!
            }
            void popFront()
                => r.popFront();
        }
        return Range(_base[]);
    }
//    auto opIndex() const
//    {
//        struct Range
//        {
//            typeof((cast(const)_base).opIndex()) r;
//
//            bool empty() const pure
//                => r.empty;
//            auto front() const
//            {
//                import urt.meta.tuple;
//                return tuple(r.front()[0], cast(Type)r.front()[1]);
////                struct KV
////                {
////                    const String* s;
////                    ref const(String) key() @property const pure
////                        => *s;
////                    const Type value;
////                }
////                return KV(&r.front.key(), cast(Type)r.front.value); // we shouldn't dynamic cast!
//            }
//            void popFront()
//                => r.popFront();
//        }
//        return Range(_base[]);
//    }
}
