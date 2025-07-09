module manager.collection;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.string;

public import manager.base;
public import manager.expression : NamedArgument;

nothrow @nogc:


const(CollectionTypeInfo)* collectionTypeInfo(Type)() nothrow @nogc
{
    static if (!is(typeof(Type.TypeName)))
        return null; // Type.TypeName must be defined
    else
    {
        import urt.mem.allocator;
        __gshared const CollectionTypeInfo ti = CollectionTypeInfo(Type.TypeName,
                                                                   allProperties!Type(),
                                                                   (){
                                                                        static if (is(typeof(Type.validateName) == function))
                                                                            return &Type.validateName;
                                                                        else
                                                                            return null;
                                                                   }(),
                                                                   (ref BaseCollection c, const(char)[] n, ObjectFlags flags)
                                                                       => defaultAllocator.allocT!Type((n ? n : c.generateName(Type.TypeName)).makeString(defaultAllocator()), flags)
                                                                   );
        return &ti;
    }
}

struct CollectionTypeInfo
{
    alias ValidateName = const(char)[] function(const(char)[] name) nothrow @nogc;
    alias CreateFun = BaseObject function(ref BaseCollection collection, const(char)[] name, ObjectFlags flags = ObjectFlags.None) nothrow @nogc;

    String type;
    const(Property*)[] properties;
    ValidateName validateName;
    CreateFun create;
}

struct BaseCollection
{
nothrow @nogc:
    const CollectionTypeInfo* typeInfo;
    Map!(String, BaseObject) pool;

    this(const CollectionTypeInfo* typeinfo)
    {
        this.typeInfo = typeinfo;
    }

    BaseObject create(const(char)[] name, ObjectFlags flags = ObjectFlags.None, in NamedArgument[] namedArgs = null)
    {
        assert(typeInfo, "Can't create into a base collection!");

        if (exists(name))
            return null;
        if (typeInfo.validateName && typeInfo.validateName(name) != null)
            return null;

        BaseObject item = alloc(name, flags);

        foreach (ref arg; namedArgs)
        {
            if (item.set(arg.name, arg.value))
            {
                defaultAllocator.freeT(item);
                return null;
            }
        }

        add(item);
        return item;
    }

    BaseObject alloc(const(char)[] name, ObjectFlags flags = ObjectFlags.None)
    {
        assert(typeInfo, "Can't create into a base collection!");
        return typeInfo.create(this, name, flags);
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

    void updateAll()
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

    const(char)[] generateName(const(char)[] prefix)
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

    BaseCollection _base = BaseCollection(collectionTypeInfo!Type);
    alias _base this;

    Type create(const(char)[] name, ObjectFlags flags = ObjectFlags.None, in NamedArgument[] namedArgs = null)
        => cast(Type)_base.create(name, flags, namedArgs);

    Type alloc(const(char)[] name)
        => cast(Type)_base.alloc(name);

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
