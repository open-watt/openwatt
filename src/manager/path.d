module manager.path;

// Normative address/pattern grammar for the data-model space (sync SUB patterns,
// discovery, api paths):
//
//   address  := ns ':' name ( '.' segment )*
//   ns       := ident | '=' ident | '*'      ; '=' = exact type, no descendants
//   name     := ident | glob
//   segment  := ident | glob
//   glob     := '*' | '**' | ident-with-'*'
//
// '*' matches one segment, '**' matches zero or more. The object-mirror sub grammar
// "[=]<type>:<name>" is this grammar with zero segments.

import urt.string;

import manager.base;
import manager.collection;
import manager.component;
import manager.element : Element;

nothrow @nogc:


struct Address
{
nothrow @nogc:

    const(char)[] ns;       // namespace/type pattern; '=' stripped into exact
    const(char)[] subject;  // name ( '.' segment )*, dotted
    bool exact;
    bool valid;

    static Address parse(const(char)[] pattern)
    {
        Address a;
        if (pattern.length == 0)
            return a;
        if (pattern[0] == '=')
        {
            a.exact = true;
            pattern = pattern[1 .. $];
        }
        foreach (i, c; pattern)
        {
            if (c == ':')
            {
                a.ns = pattern[0 .. i];
                a.subject = pattern[i + 1 .. $];
                a.valid = true;
                return a;
            }
        }
        return a;
    }
}

// Dotted segment-wise match. `star_descends` gives legacy api semantics where '*'
// also matches any depth (i.e. behaves as '**').
bool match_path(const(char)[] pattern, const(char)[] path, bool star_descends = false)
{
    if (pattern.length == 0)
        return path.length == 0;
    const(char)[] pat = pattern;
    const(char)[] p = pat.split!'.';
    if (p == "**" || (star_descends && p == "*"))
    {
        if (match_path(pat, path, star_descends))
            return true;
        if (path.length == 0)
            return false;
        const(char)[] rest = path;
        rest.split!'.';
        return match_path(pattern, rest, star_descends);
    }
    if (path.length == 0)
        return false;
    const(char)[] rest = path;
    const(char)[] s = rest.split!'.';
    return wildcard_match(p, s) && match_path(pat, rest, star_descends);
}

// Subscription pattern forms (zero-segment addresses):
//   "[=]<type>:<name>"    - type/name match; both halves accept wildcards.
//                           Without '=' the type half matches any ancestor.
//     "modbus:goodwe_ems"  - any modbus (incl. subtypes) named goodwe_ems
//     "=modbus:goodwe_ems" - only objects whose concrete type is exactly "modbus"
//     "interface:*"        - everything derived from "interface"
//     "*:*"                - everything
bool matches_object(ref const Address a, BaseObject obj)
{
    if (!a.valid || !wildcard_match(a.subject, obj.name[]))
        return false;
    if (a.exact)
        return wildcard_match(a.ns, obj.type);
    for (const(CollectionTypeInfo)* ti = obj._typeInfo; ti !is null; ti = ti.collection_super())
    {
        if (wildcard_match(a.ns, ti.type[]))
            return true;
    }
    return false;
}

bool pattern_matches(const(char)[] pattern, BaseObject obj)
    => matches_object(Address.parse(pattern), obj);

alias ElementVisitor = void delegate(Element* e, const(char)[] path) nothrow @nogc;
alias ElementProbe = bool delegate(Element* e, const(char)[] path) nothrow @nogc;

void walk_elements(Component root, const(char)[] pattern, scope ElementVisitor visit, bool star_descends = false)
{
    walk_elements_until(root, pattern, (Element* e, const(char)[] path)
    {
        visit(e, path);
        return true;
    }, star_descends);
}

bool walk_elements_until(Component root, const(char)[] pattern, scope ElementProbe probe, bool star_descends = false)
{
    MutableString!0 path;
    bool complete = true;
    void walk(Component c)
    {
        if (!complete)
            return;
        size_t reset = path.length;
        if (reset)
            path ~= '.';
        path ~= c.id[];
        size_t base = path.length;
        foreach (Element* e; c.elements)
        {
            path.append('.', e.id[]);
            if (match_path(pattern, path[], star_descends) && !probe(e, path[]))
                complete = false;
            path.erase(base, path.length - base);
            if (!complete)
                break;
        }
        foreach (Component child; c.components)
        {
            if (!complete)
                break;
            walk(child);
        }
        path.erase(reset, path.length - reset);
    }
    walk(root);
    return complete;
}


unittest
{
    Address a = Address.parse("modbus:inv");
    assert(a.valid && !a.exact && a.ns == "modbus" && a.subject == "inv");
    a = Address.parse("=modbus:inv.battery.voltage");
    assert(a.valid && a.exact && a.ns == "modbus" && a.subject == "inv.battery.voltage");
    a = Address.parse("*:");
    assert(a.valid && a.ns == "*" && a.subject.length == 0);
    assert(!Address.parse("no-colon").valid);
    assert(!Address.parse("").valid);

    assert(match_path("a.b.c", "a.b.c"));
    assert(!match_path("a.b.c", "a.b"));
    assert(!match_path("a.b", "a.b.c"));
    assert(match_path("a.*.c", "a.b.c"));
    assert(!match_path("a.*.c", "a.c"));
    assert(!match_path("a.*.c", "a.b.b.c"));
    assert(match_path("a.**.c", "a.c"));
    assert(match_path("a.**.c", "a.b.c"));
    assert(match_path("a.**.c", "a.x.y.c"));
    assert(match_path("**", ""));
    assert(match_path("**", "a.b.c"));
    assert(match_path("volt*", "voltage"));
    assert(match_path("a.volt*", "a.voltage"));
    assert(!match_path("a.volt*", "a.current"));

    // legacy api semantics: '*' descends
    assert(match_path("a.*", "a.b.c", true));
    assert(!match_path("a.*", "a.b.c"));
    assert(match_path("*.voltage", "a.b.voltage", true));

    // element walk over a small tree
    import urt.mem;
    Component root = alloc!Component(StringLit!"dev");
    Component child = alloc!Component(StringLit!"battery");
    child.parent = root;
    root.components ~= child;
    Element e1, e2;
    e1.id = StringLit!"voltage";
    e2.id = StringLit!"current";
    e1.parent = child;
    e2.parent = root;
    child.elements ~= &e1;
    root.elements ~= &e2;

    static struct Hits
    {
        uint count;
        char[64] last;
        size_t last_len;
        void visit(Element* e, const(char)[] path) nothrow @nogc
        {
            ++count;
            last[0 .. path.length] = path[];
            last_len = path.length;
        }
    }
    Hits h;
    walk_elements(root, "dev.battery.voltage", &h.visit);
    assert(h.count == 1 && h.last[0 .. h.last_len] == "dev.battery.voltage");
    h = Hits.init;
    walk_elements(root, "dev.**", &h.visit);
    assert(h.count == 2);
    h = Hits.init;
    walk_elements(root, "*.voltage", &h.visit, true);
    assert(h.count == 1);

    free(child);
    free(root);
}
