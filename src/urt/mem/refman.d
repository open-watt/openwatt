module urt.mem.refman;

enum MaxRefs = 1024;

size_t[MaxRefs] ptrs;
ubyte[MaxRefs/8] allocMask;
ushort allocOffset = 0;

struct ShortRef(T)
{
    static assert(is(T == void*) || is(T == void[]), "ShortRef can only be used with T* or T[]");

    T getRef()
    {
        static if (is(T == void*))
            return cast(T)ptrs[_ref];
        else static if (is(T == void[]))
            return *cast(T*)&ptrs[_ref];
    }
    alias getRef this;

private:
    ushort _ref;
}


ShortRef!(void*) getRef(void* ptr)
{
    return ShortRef!(void*)();
}

ShortRef!(void[]) getRef(void[] array)
{
    return ShortRef!(void[])();
}
