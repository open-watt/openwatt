module protocol.mqtt.topic;

import urt.array;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.string;
import urt.time;

nothrow @nogc:


// In-process delivery for bindings. Wire-side subscribers (Session) leave callback null; the broker dispatches them by formatting a PUBLISH packet.
alias PublishCallback = void delegate(const(char)[] sender, const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp) nothrow @nogc;

// Topic length capped at 65535 (on-wire 2-byte length prefix). `$`-prefixed topics are reserved: root-level `#` and `+` MUST NOT match them (MQTT-4.7.2-1).
bool validate_topic_name(const(char)[] name) pure
{
    if (name.length == 0 || name.length > 0xFFFF)
        return false;
    foreach (c; name)
    {
        if (c == '\0' || c == '+' || c == '#')
            return false;
    }
    return true;
}

bool validate_topic_filter(const(char)[] filter) pure
{
    if (filter.length == 0 || filter.length > 0xFFFF)
        return false;

    bool at_level_start = true;
    foreach (i, c; filter)
    {
        if (c == '\0')
            return false;
        if (c == '/')
        {
            at_level_start = true;
            continue;
        }
        if (c == '#')
        {
            // # must be the last character of the filter AND occupy its own level
            if (!at_level_start || i != filter.length - 1)
                return false;
        }
        else if (c == '+')
        {
            // + must occupy an entire level
            if (!at_level_start)
                return false;
            if (i + 1 < filter.length && filter[i + 1] != '/')
                return false;
        }
        at_level_start = false;
    }
    return true;
}

bool topic_matches_filter(const(char)[] topic, const(char)[] filter) pure
{
    bool dollar_topic = topic.length > 0 && topic[0] == '$';

    size_t t_start = 0;
    size_t f_start = 0;
    bool first_level = true;

    while (true)
    {
        size_t f_end = f_start;
        while (f_end < filter.length && filter[f_end] != '/')
            ++f_end;
        const(char)[] f_level = filter[f_start .. f_end];

        if (f_level == "#")
        {
            if (first_level && dollar_topic)
                return false;
            return true;
        }

        size_t t_end = t_start;
        while (t_end < topic.length && topic[t_end] != '/')
            ++t_end;
        const(char)[] t_level = topic[t_start .. t_end];

        if (f_level == "+")
        {
            if (first_level && dollar_topic)
                return false;
            if (t_start >= topic.length)
                return false;
        }
        else
        {
            if (f_level != t_level)
                return false;
        }

        bool f_done = f_end >= filter.length;
        bool t_done = t_end >= topic.length;

        if (f_done && t_done)
            return true;
        if (t_done)
        {
            // topic exhausted -- matches only if filter continues with `/#`
            return filter[f_end .. $] == "/#";
        }
        if (f_done)
            return false;

        f_start = f_end + 1;
        t_start = t_end + 1;
        first_level = false;
    }
}

// `subscriber` is an opaque identity: dedupes registrations on the same filter and is what the broker compares against for NoLocal.
struct Subscription
{
    void* subscriber;
    PublishCallback callback;    // null => wire subscriber; broker dispatches via session.connection
    uint subscription_id;        // 0 = unset
    ubyte qos;
    bool no_local;
    bool retain_as_published;
    ubyte retain_handling;
}

struct RetainedMessage
{
    @disable this(this);

    String topic;
    Array!ubyte payload;
    Array!ubyte properties;
    ubyte flags;
}

// Caller pre-validates filters/names; the trie trusts its inputs.
struct TopicTrie
{
nothrow @nogc:
    @disable this(this);

    ~this()
    {
        clear();
    }

    void clear()
    {
        clear_node_contents(&_root);
    }

    // Returns true for a new subscription, false for an upsert of (filter, subscriber).
    bool register(const(char)[] filter, Subscription sub)
    {
        return register_impl(&_root, filter, sub);
    }

    bool unregister(const(char)[] filter, void* subscriber)
    {
        return unregister_impl(&_root, filter, subscriber);
    }

    // Sweeps every filter held by `subscriber` -- lets unsubscribe(callback) work without the caller tracking which filters it registered.
    void unregister_all(void* subscriber)
    {
        unregister_all_impl(&_root, subscriber);
    }

    // A subscriber may be visited multiple times for overlapping filters; per MQTT-3.3.4-2 it's the broker's job to merge.
    void match_subscribers(const(char)[] topic, scope void delegate(ref const Subscription) nothrow @nogc cb)
    {
        match_subs_impl(&_root, topic, true, cb);
    }

    // Empty payload clears any retained message at `topic` (per spec).
    void store_retained(const(char)[] topic, const(ubyte)[] payload, const(ubyte)[] properties, ubyte flags)
    {
        if (payload.length == 0)
            clear_retained_impl(&_root, topic);
        else
            set_retained_impl(&_root, topic, topic, payload, properties, flags);
    }

    void match_retained(const(char)[] filter, scope void delegate(ref const RetainedMessage) nothrow @nogc cb)
    {
        match_retained_impl(&_root, filter, true, cb);
    }

private:

    struct Node
    {
        Map!(String, Node*) literal_children;
        Node* plus_child;
        Array!Subscription exact_subs;
        Array!Subscription multi_subs;
        RetainedMessage* retained;
    }

    Node _root;

    static bool register_impl(Node* node, const(char)[] filter, Subscription sub)
    {
        char sep;
        const(char)[] level = filter.split!'/'(sep);

        if (level == "#")
            return upsert(node.multi_subs, sub);

        Node* next;
        if (level == "+")
        {
            if (!node.plus_child)
                node.plus_child = defaultAllocator().allocT!Node;
            next = node.plus_child;
        }
        else
        {
            Node** existing = level in node.literal_children;
            if (existing)
                next = *existing;
            else
            {
                next = defaultAllocator().allocT!Node;
                node.literal_children.insert(level.makeString(defaultAllocator()), next);
            }
        }

        if (sep == 0)
            return upsert(next.exact_subs, sub);
        return register_impl(next, filter, sub);
    }

    static bool unregister_impl(Node* node, const(char)[] filter, void* subscriber)
    {
        char sep;
        const(char)[] level = filter.split!'/'(sep);

        if (level == "#")
            return remove_matching(node.multi_subs, subscriber);

        Node* next;
        if (level == "+")
            next = node.plus_child;
        else
        {
            Node** existing = level in node.literal_children;
            if (existing)
                next = *existing;
        }
        if (!next)
            return false;

        if (sep == 0)
            return remove_matching(next.exact_subs, subscriber);
        return unregister_impl(next, filter, subscriber);
    }

    static bool upsert(ref Array!Subscription subs, Subscription sub)
    {
        foreach (ref existing; subs)
        {
            if (existing.subscriber is sub.subscriber)
            {
                existing = sub;
                return false;
            }
        }
        subs ~= sub;
        return true;
    }

    static bool remove_matching(ref Array!Subscription subs, void* subscriber)
    {
        for (size_t i = 0; i < subs.length; ++i)
        {
            if (subs[i].subscriber is subscriber)
            {
                subs.removeSwapLast(i);
                return true;
            }
        }
        return false;
    }

    static void unregister_all_impl(Node* node, void* subscriber)
    {
        sweep(node.exact_subs, subscriber);
        sweep(node.multi_subs, subscriber);
        if (node.plus_child)
            unregister_all_impl(node.plus_child, subscriber);
        foreach (kvp; node.literal_children)
            unregister_all_impl(kvp.value, subscriber);
    }

    static void sweep(ref Array!Subscription subs, void* subscriber)
    {
        for (size_t i = 0; i < subs.length; )
        {
            if (subs[i].subscriber is subscriber)
                subs.removeSwapLast(i);
            else
                ++i;
        }
    }

    static void match_subs_impl(Node* node, const(char)[] topic, bool first_level, scope void delegate(ref const Subscription) nothrow @nogc cb)
    {
        bool dollar_root = first_level && topic.length > 0 && topic[0] == '$';

        if (!dollar_root)
            foreach (ref sub; node.multi_subs)
                cb(sub);

        if (topic.length == 0)
        {
            foreach (ref sub; node.exact_subs)
                cb(sub);
            return;
        }

        char sep;
        const(char)[] level = topic.split!'/'(sep);

        Node** lit = level in node.literal_children;
        if (lit)
            match_subs_impl(*lit, topic, false, cb);

        if (!dollar_root && node.plus_child)
            match_subs_impl(node.plus_child, topic, false, cb);
    }

    static void set_retained_impl(Node* node, const(char)[] topic_full, const(char)[] topic_remaining, const(ubyte)[] payload, const(ubyte)[] properties, ubyte flags)
    {
        char sep;
        const(char)[] level = topic_remaining.split!'/'(sep);

        Node* next;
        Node** existing = level in node.literal_children;
        if (existing)
            next = *existing;
        else
        {
            next = defaultAllocator().allocT!Node;
            node.literal_children.insert(level.makeString(defaultAllocator()), next);
        }

        if (sep == 0)
        {
            if (!next.retained)
                next.retained = defaultAllocator().allocT!RetainedMessage;
            next.retained.topic = topic_full.makeString(defaultAllocator());
            next.retained.payload = payload;
            next.retained.properties = properties;
            next.retained.flags = flags;
            return;
        }

        set_retained_impl(next, topic_full, topic_remaining, payload, properties, flags);
    }

    static void clear_retained_impl(Node* node, const(char)[] topic)
    {
        char sep;
        const(char)[] level = topic.split!'/'(sep);

        Node** existing = level in node.literal_children;
        if (!existing)
            return;
        Node* next = *existing;

        if (sep == 0)
        {
            if (next.retained)
            {
                defaultAllocator().freeT(next.retained);
                next.retained = null;
            }
            return;
        }

        clear_retained_impl(next, topic);
    }

    static void match_retained_impl(Node* node, const(char)[] filter, bool first_level, scope void delegate(ref const RetainedMessage) nothrow @nogc cb)
    {
        char sep;
        const(char)[] level = filter.split!'/'(sep);

        if (level == "#")
        {
            enumerate_retained(node, first_level, cb);
            return;
        }

        if (level == "+")
        {
            foreach (kvp; node.literal_children)
            {
                if (first_level && kvp.key[].length > 0 && kvp.key[][0] == '$')
                    continue;
                if (sep == 0)
                {
                    if (kvp.value.retained)
                        cb(*kvp.value.retained);
                }
                else
                    match_retained_impl(kvp.value, filter, false, cb);
            }
            return;
        }

        Node** existing = level in node.literal_children;
        if (!existing)
            return;
        if (sep == 0)
        {
            if ((*existing).retained)
                cb(*(*existing).retained);
        }
        else
            match_retained_impl(*existing, filter, false, cb);
    }

    static void enumerate_retained(Node* node, bool first_level, scope void delegate(ref const RetainedMessage) nothrow @nogc cb)
    {
        if (node.retained)
            cb(*node.retained);
        foreach (kvp; node.literal_children)
        {
            if (first_level && kvp.key[].length > 0 && kvp.key[][0] == '$')
                continue;
            enumerate_retained(kvp.value, false, cb);
        }
    }

    static void clear_node_contents(Node* node)
    {
        foreach (kvp; node.literal_children)
        {
            clear_node_contents(kvp.value);
            defaultAllocator().freeT(kvp.value);
        }
        node.literal_children.clear();

        if (node.plus_child)
        {
            clear_node_contents(node.plus_child);
            defaultAllocator().freeT(node.plus_child);
            node.plus_child = null;
        }

        node.exact_subs.clear();
        node.multi_subs.clear();

        if (node.retained)
        {
            defaultAllocator().freeT(node.retained);
            node.retained = null;
        }
    }
}


unittest
{
    {
        // validate_topic_name
        assert( validate_topic_name("a"));
        assert( validate_topic_name("a/b/c"));
        assert( validate_topic_name("/"));
        assert( validate_topic_name("//"));
        assert( validate_topic_name("$SYS/load"));

        assert(!validate_topic_name(""));
        assert(!validate_topic_name("a/+"));
        assert(!validate_topic_name("a/#"));
        assert(!validate_topic_name("\0"));
        assert(!validate_topic_name("foo\0bar"));
    }

    {
        // validate_topic_filter
        assert( validate_topic_filter("a"));
        assert( validate_topic_filter("a/b"));
        assert( validate_topic_filter("#"));
        assert( validate_topic_filter("a/#"));
        assert( validate_topic_filter("a/b/#"));
        assert( validate_topic_filter("+"));
        assert( validate_topic_filter("+/+"));
        assert( validate_topic_filter("a/+/b"));
        assert( validate_topic_filter("+/#"));
        assert( validate_topic_filter("$SYS/+"));
        assert( validate_topic_filter("/"));
        assert( validate_topic_filter("a//b"));

        assert(!validate_topic_filter("#/"));
        assert(!validate_topic_filter("a/#/b"));
        assert(!validate_topic_filter("a#"));
        assert(!validate_topic_filter("#a"));
        assert(!validate_topic_filter("a/b#"));

        assert(!validate_topic_filter("a+"));
        assert(!validate_topic_filter("+a"));
        assert(!validate_topic_filter("a/+b"));
        assert(!validate_topic_filter("a/b+"));

        assert(!validate_topic_filter(""));
        assert(!validate_topic_filter("\0"));
        assert(!validate_topic_filter("a/\0/b"));
    }

    {
        // topic_matches_filter -- literal
        assert( topic_matches_filter("a", "a"));
        assert( topic_matches_filter("a/b", "a/b"));
        assert(!topic_matches_filter("a/b", "a"));
        assert(!topic_matches_filter("a", "a/b"));
        assert(!topic_matches_filter("a/b", "a/c"));
    }

    {
        // topic_matches_filter -- + wildcard
        assert( topic_matches_filter("a", "+"));
        assert( topic_matches_filter("a/b", "+/b"));
        assert( topic_matches_filter("a/b", "a/+"));
        assert( topic_matches_filter("a/b/c", "+/+/+"));
        assert( topic_matches_filter("a//b", "a/+/b"));
        assert(!topic_matches_filter("a/b/c", "+/+"));
        assert(!topic_matches_filter("a", "+/+"));
    }

    {
        // topic_matches_filter -- # wildcard
        assert( topic_matches_filter("a", "#"));
        assert( topic_matches_filter("a/b", "#"));
        assert( topic_matches_filter("a/b/c", "#"));
        assert( topic_matches_filter("a", "a/#"));
        assert( topic_matches_filter("a/b", "a/#"));
        assert( topic_matches_filter("a/b/c", "a/#"));
        assert( topic_matches_filter("a/b/c", "a/b/#"));
        assert(!topic_matches_filter("b", "a/#"));
        assert(!topic_matches_filter("ab", "a/#"));
    }

    {
        // topic_matches_filter -- $ reserved prefix
        assert(!topic_matches_filter("$SYS/x", "#"));
        assert(!topic_matches_filter("$SYS/x", "+/x"));
        assert(!topic_matches_filter("$SYS", "+"));
        assert(!topic_matches_filter("$SYS", "#"));

        assert( topic_matches_filter("$SYS/x", "$SYS/x"));
        assert( topic_matches_filter("$SYS/x", "$SYS/+"));
        assert( topic_matches_filter("$SYS/x", "$SYS/#"));
        assert( topic_matches_filter("$SYS/a/b", "$SYS/+/b"));
    }

    {
        // TopicTrie -- subscribe and match
        TopicTrie trie;

        int subA, subB, subC;
        Subscription sub_a = { subscriber: &subA, qos: 0 };
        Subscription sub_b = { subscriber: &subB, qos: 1 };
        Subscription sub_c = { subscriber: &subC, qos: 2 };

        assert(trie.register("a/b", sub_a));
        assert(trie.register("a/+", sub_b));
        assert(trie.register("#", sub_c));

        size_t hits;
        bool got_a, got_b, got_c;
        trie.match_subscribers("a/b", (ref const Subscription s) {
            ++hits;
            if (s.subscriber is &subA)
                got_a = true;
            if (s.subscriber is &subB)
                got_b = true;
            if (s.subscriber is &subC)
                got_c = true;
        });
        assert(hits == 3);
        assert(got_a && got_b && got_c);

        hits = 0; got_a = got_b = got_c = false;
        trie.match_subscribers("a/c", (ref const Subscription s) {
            ++hits;
            if (s.subscriber is &subA)
                got_a = true;
            if (s.subscriber is &subB)
                got_b = true;
            if (s.subscriber is &subC)
                got_c = true;
        });
        assert(hits == 2);
        assert(!got_a && got_b && got_c);

        hits = 0; got_c = false;
        trie.match_subscribers("x", (ref const Subscription s) {
            ++hits;
            if (s.subscriber is &subC)
                got_c = true;
        });
        assert(hits == 1 && got_c);
    }

    {
        // TopicTrie -- # at root suppressed for $-topics
        TopicTrie trie;
        int subA, subB;
        Subscription sub_a = { subscriber: &subA };
        Subscription sub_b = { subscriber: &subB };

        trie.register("#", sub_a);
        trie.register("$SYS/#", sub_b);

        size_t a_hits, b_hits;
        trie.match_subscribers("$SYS/load", (ref const Subscription s) {
            if (s.subscriber is &subA)
                ++a_hits;
            if (s.subscriber is &subB)
                ++b_hits;
        });
        assert(a_hits == 0);
        assert(b_hits == 1);

        a_hits = b_hits = 0;
        trie.match_subscribers("foo/bar", (ref const Subscription s) {
            if (s.subscriber is &subA)
                ++a_hits;
            if (s.subscriber is &subB)
                ++b_hits;
        });
        assert(a_hits == 1);
        assert(b_hits == 0);
    }

    {
        // TopicTrie -- upsert and unregister
        TopicTrie trie;
        int subA;
        Subscription v1 = { subscriber: &subA, qos: 0 };
        Subscription v2 = { subscriber: &subA, qos: 2 };

        assert( trie.register("a/b", v1));
        assert(!trie.register("a/b", v2));

        ubyte got_qos;
        trie.match_subscribers("a/b", (ref const Subscription s) {
            if (s.subscriber is &subA)
                got_qos = s.qos;
        });
        assert(got_qos == 2);

        assert( trie.unregister("a/b", &subA));
        assert(!trie.unregister("a/b", &subA));

        size_t hits;
        trie.match_subscribers("a/b", (ref const Subscription) { ++hits; });
        assert(hits == 0);
    }

    {
        // TopicTrie -- store_retained / match_retained
        TopicTrie trie;

        static immutable ubyte[] p1 = [1, 2, 3];
        static immutable ubyte[] p2 = [4, 5];
        static immutable ubyte[] empty;

        trie.store_retained("a/b", p1, null, 0);
        trie.store_retained("a/c", p2, null, 0);
        trie.store_retained("x/y", p1, null, 0);

        size_t hits;
        bool got_ab, got_ac, got_xy;
        trie.match_retained("a/+", (ref const RetainedMessage rm) {
            ++hits;
            if (rm.topic[] == "a/b")
                got_ab = true;
            if (rm.topic[] == "a/c")
                got_ac = true;
            if (rm.topic[] == "x/y")
                got_xy = true;
        });
        assert(hits == 2);
        assert(got_ab && got_ac && !got_xy);

        hits = 0; got_ab = got_ac = got_xy = false;
        trie.match_retained("#", (ref const RetainedMessage rm) {
            ++hits;
            if (rm.topic[] == "a/b")
                got_ab = true;
            if (rm.topic[] == "a/c")
                got_ac = true;
            if (rm.topic[] == "x/y")
                got_xy = true;
        });
        assert(hits == 3);
        assert(got_ab && got_ac && got_xy);

        trie.store_retained("a/b", empty, null, 0);
        hits = 0;
        trie.match_retained("a/b", (ref const RetainedMessage) { ++hits; });
        assert(hits == 0);

        hits = 0;
        trie.match_retained("a/c", (ref const RetainedMessage) { ++hits; });
        assert(hits == 1);
    }

    {
        // TopicTrie -- retained payload is owned (slice-of-source can be freed)
        TopicTrie trie;
        {
            ubyte[5] scratch = [10, 20, 30, 40, 50];
            trie.store_retained("a", scratch[], null, 0);
            scratch[0] = 99;
        }
        static immutable ubyte[5] expected = [10, 20, 30, 40, 50];
        trie.match_retained("a", (ref const RetainedMessage rm) {
            assert(rm.payload[] == expected[]);
        });
    }

    {
        // TopicTrie -- clear() drops everything
        TopicTrie trie;
        int subA;
        Subscription s = { subscriber: &subA };

        trie.register("a/+/b", s);
        trie.register("#", s);
        static immutable ubyte[] p = [1];
        trie.store_retained("x/y/z", p, null, 0);

        trie.clear();

        size_t sub_hits, ret_hits;
        trie.match_subscribers("a/x/b", (ref const Subscription) { ++sub_hits; });
        trie.match_retained("#",       (ref const RetainedMessage) { ++ret_hits; });
        assert(sub_hits == 0);
        assert(ret_hits == 0);
    }
}
