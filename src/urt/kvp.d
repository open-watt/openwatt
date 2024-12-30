module urt.kvp;

import urt.lifetime : forward;

nothrow @nogc:


struct KVP(K, V)
{
nothrow @nogc:

    this(this) @disable;

//    this(KVP!(K, V) kvp)
//    {
//        this.key = kvp.key.move;
//        this.value = kvp.value.move;
//    }
    this(ref KVP!(K, V) kvp)
    {
        this.key = kvp.key;
        this.value = kvp.value;
    }

    this(_K, _V)(auto ref _K key, auto ref _V value)
    {
        this.key = forward!key;
        this.value = forward!value;
    }

    bool opEquals(U, V)(auto ref KVP!(U, V) other) const
    {
        return key == other.key && value == other.value;
    }

    int opCmp(U, V)(auto ref KVP!(U, V) other) const
    {
        if (key < other.key)
            return -1;
        if (key > other.key)
            return 1;
        if (value < other.value)
            return -1;
        if (value > other.value)
            return 1;
        return 0;
    }

    // TODO: consider, should value be first? it is more likely to have alignment requirements.
    //       conversely, key is more frequently accessed, so should be in the first cache line...
    K key;
    V value;
}
