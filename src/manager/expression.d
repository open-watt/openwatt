module manager.expression;

import urt.array;
import urt.conv;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.si.unit;
import urt.si.quantity;
import urt.string;

public import urt.variant;

import manager.value;
import manager.series : FormatId;

//version = ExpressionDebug;

@nogc:


enum Type : ubyte
{
    // primary
    str = 0,
    num,
    null_,
    var,
    elem,
    arr,

    // lists
    exp_list,
    cmd_list,

    // unary
    neg,
    not,

    // postfix
    idx,
    call,

    // binary
    or,
    and,
    eq,
    ne,
    lt,
    le,
    cat,
    add,
    sub,
    mul,
    div,
}

enum Flags : ubyte
{
    identifier = 1 << 0,
    interpolated_string = 1 << 1,
    command_eval = 1 << 2,
    constant = 1 << 3,
    no_quotes = 1 << 4,
    allocated = 1 << 5,
}

struct NamedArgument
{
    this(ref NamedArgument rh) nothrow @nogc
    {
        name = rh.name;
        value = rh.value;
    }

    this(T)(const(char)[] name, auto ref T value) nothrow @nogc
    {
        this.name = name;
        this.value = to_variant(forward!value);
    }

    const(char)[] name;
    Variant value;
}


struct ScriptCommand
{
    const(char)[] command;
    Array!(Expression*) args;
    Array!Argument named_args;

    struct Argument
    {
        Expression* name;
        Expression* value;
    }
}

struct EvalContext
{
    import manager.component;

    Component root;
    Map!(String, Variant)* locals;
    Map!(const(Expression)*, Variant)* sub_results;
    bool types_only;    // element refs evaluate as format exemplars, not current values
}

// a representative value of a format, for evaluating an expression's TYPE before any data
// exists: numerics are unit-carrying double zeros (derived formats are f64 by policy, and
// zeros dodge integer division), text is empty, anything else refuses to compute
private Variant format_exemplar(FormatId id) nothrow @nogc
{
    import manager.series : DataFormat, format_info, value_class, ValueClass, ValueType;
    import urt.si.quantity : Quantity;
    import urt.si.unit : ScaledUnit;

    const(DataFormat)* f = format_info(id);
    if (f.is_text)
        return Variant("");
    if (f.desc == DataFormat.Desc.quantity)
        return Variant(Quantity!double(0, f.unit));
    if (f.type == ValueType.bool_)
        return Variant(false);
    if (f.desc == DataFormat.Desc.none && value_class(f.type) != ValueClass.exact && f.count == 1)
        return Variant(0.0);
    return Variant(null);
}

struct Script
{
nothrow @nogc:

    this(typeof(null)) inout pure { }

    this(ref const Script rhs) inout pure
    {
        if (rhs.p)
            ++(cast(Payload*)rhs.p).refcount;
        p = cast(inout(Payload)*)rhs.p;
    }

    ~this() pure
    {
        if (p && --(cast(Payload*)p).refcount == 0)
            defaultAllocator().freeT(cast(Payload*)p);
    }

    void opAssign(typeof(null))
    {
        if (p)
        {
            if (--(cast(Payload*)p).refcount == 0)
                defaultAllocator().freeT(cast(Payload*)p);
            p = null;
        }
    }

    void opAssign(ref const Script rhs)
    {
        if (rhs.p is p)
            return;
        if (rhs.p)
            ++(cast(Payload*)rhs.p).refcount;
        if (p && --(cast(Payload*)p).refcount == 0)
            defaultAllocator().freeT(cast(Payload*)p);
        p = cast(Payload*)rhs.p;
    }

    void opAssign(Script rhs)
    {
        auto tmp = p;
        p = rhs.p;
        rhs.p = tmp;
    }

    bool empty() const pure
        => p is null;

    const(ScriptCommand)[] commands() const pure
        => p ? p.commands[] : null;

    const(char)[] source() const pure
        => p ? p.source[] : null;

private:
    static struct Payload
    {
        Array!char source;
        Array!ScriptCommand commands;
        uint refcount;
    }
    Payload* p;
}

Script make_script(const(char)[] source_text) nothrow @nogc
{
    Script b;
    b.p = defaultAllocator().allocT!(Script.Payload)();
    b.p.refcount = 1;
    b.p.source ~= source_text;
    const(char)[] cursor = b.p.source[];
    try
        b.p.commands = parse_commands(cursor);
    catch (Exception)
    {
    }
    return b;
}

bool is_truthy(ref const Variant v) nothrow @nogc
{
    if (v.isBool)
        return v.asBool;
    if (v.isNumber)
    {
        if (v.isLong)
            return v.asLong != 0;
        return v.asDouble != 0;
    }
    if (v.isString)
        return v.asString.length != 0;
    return false;
}

struct Expression
{
nothrow @nogc:

    this(Type ty)
    {
        this.ty = ty;
    }

    this(bool b)
    {
        ty = Type.num;
        f = b ? 1 : 0;
    }

    this(S : MutableString!0)(auto ref S s)
    {
        ty = Type.str;
        flags = Flags.allocated; // TODO: we might need to scan for variable references...
        new(str) typeof(str)(forward!s);
    }

    ~this()
    {
        if (is_string())
            str.destroy!false();
        else if (ty == Type.arr)
            arr.destroy!false();
        else if (ty == Type.cmd_list)
            cmds.list.destroy!false();
        else if (ty >= Type.neg)
        {
            left.free_expression();
            if (ty >= Type.idx)
                right.free_expression();
        }
    }

    // HACK: the copy assignment actually moves for now (!!)
    void opAssign(ref Expression e)// @disable; // only accept move's...
//    void opAssign(Expression e)
    {
        this.destroy!false();
        ty = e.ty;
        flags = e.flags;
        _reserve = e._reserve;
        e._reserve[] = 0;
        e.flags &= ~Flags.allocated;
    }

    void opAssign(S : String)(auto ref S s)
    {
        this.destroy!false();
        ty = Type.str;
        flags = Flags.allocated; // TODO: we might need to scan for variable references...
        new(str) typeof(str)(forward!s);
        s.length = 0;
    }

    Array!(const(char)[]) get_element_refs(ref bool has_var_refs) const
    {
        Array!(const(char)[]) r;
        gather_elements(r, has_var_refs);
        return r;
    }

    bool is_string() const
        => (ty == Type.str || ty == Type.var || ty == Type.elem) && (flags & Flags.allocated) != 0;

    bool is_command_eval() const
        => ty == Type.cmd_list && (flags & Flags.command_eval) != 0;

    const(ScriptCommand)[] cmd_list() const
    {
        assert(ty == Type.cmd_list);
        return cmds.list[];
    }

    const(char)[] cmd_list_source() const
    {
        assert(ty == Type.cmd_list);
        return cmds.source;
    }

    void gather_command_evals(ref Array!(const(Expression)*) subs) const
    {
        switch (ty)
        {
            case Type.cmd_list:
                if (flags & Flags.command_eval)
                    subs ~= &this;
                break;
            case Type.arr:
                foreach (e; arr)
                    e.gather_command_evals(subs);
                break;
            case Type.exp_list, Type.idx, Type.call, Type.cat,
                 Type.or, Type.and, Type.eq, Type.ne, Type.lt, Type.le,
                 Type.add, Type.sub, Type.mul, Type.div:
                left.gather_command_evals(subs);
                right.gather_command_evals(subs);
                break;
            case Type.neg, Type.not:
                left.gather_command_evals(subs);
                break;
            default:
                break;
        }
    }

    bool as_bool() const
    {
        switch (ty)
        {
            case Type.num: return f.value != 0 || f.unit != ScaledUnit(); // NOTE: 0V is 'true'! is this right?
            case Type.str: return get_str().length != 0;
            default:
                // this is just for getting constants; we don't do expression evaluation here...
                assert(false);
        }
    }

    VarQuantity as_num() const
    {
        switch (ty)
        {
            case Type.num: return f;
            case Type.str:
                size_t taken;
                VarQuantity q = get_str().parse_quantity(&taken);
                if (taken != s.length)
                    return VarQuantity(0);
                return q;
            default:
                // this is just for getting constants; we don't do expression evaluation here...
                assert(false);
        }
    }

    const(char)[] get_str() const
    {
        if (ty == Type.str || ty == Type.var || ty == Type.elem)
            return (flags & Flags.allocated) ? str[] : s;
        assert(false);
    }

    Variant evaluate(ref EvalContext ctx) const
    {
        import urt.si.quantity;

        import manager;
        import manager.element;

        static int as_bool(ref const Variant v)
        {
            if (v.isBool)
                return v.asBool;
            if (v.isNumber)
            {
                if (v.isLong) // this saves an int/float conversation at the cost of an if...
                    return v.asLong != 0;
                return v.asDouble != 0;
            }
            if (v.isString)
                return v.asString.length != 0;
            return -1;
        }

        static bool as_quantity(ref const Variant v, out VarQuantity r)
        {
            if (v.isNumber)
            {
                r = v.asQuantity;
                return true;
            }
            if (v.isString)
            {
                size_t taken;
                const(char)[] str = v.asString;
                VarQuantity q = str.parse_quantity(&taken);
                if (taken != str.length)
                    return false;
                r = q;
                return true;
            }
            return false;
        }

        final switch (ty)
        {
            case Type.null_:
                return Variant();
            case Type.num:
                return Variant(f);
            case Type.str:
                return Variant(get_str());
            case Type.var:
                if (ctx.locals !is null)
                {
                    const(char)[] path = get_str();
                    const(char)[] first = path.split!'.';
                    if (Variant* val = first in *ctx.locals)
                    {
                        Variant* current = val;
                        while (!path.empty && current !is null && current.isObject)
                        {
                            const(char)[] segment = path.split!'.';
                            current = current.getMember(segment);
                        }
                        if (current !is null && path.empty)
                            return *current;
                    }
                }
                return Variant(null);
            case Type.elem:
                const(char)[] id = get_str();
                const bool absolute = id.length > 0 && id[0] == '.';
                if (absolute)
                    id = id[1 .. $];
                Element* e = (!absolute && ctx.root) ? ctx.root.find_element(id) : g_app.find_element(id);
                if (e)
                    return ctx.types_only ? format_exemplar(e.format) : Variant(e.value);
                return Variant(null);
            case Type.arr:
                Variant r;
                ref Array!Variant va = r.asArray();
                foreach (e; arr)
                    va ~= e.evaluate(ctx);
                return r.move;
            case Type.cmd_list:
                if (flags & Flags.command_eval)
                {
                    if (ctx.sub_results !is null)
                        if (Variant* val = &this in *ctx.sub_results)
                            return *val;
                    return Variant(null);
                }
                return Variant(make_script(cmds.source));
            case Type.exp_list:
                assert(false, "Only for function args");
            case Type.neg:
                Variant v = left.evaluate(ctx);
                VarQuantity num;
                if (!as_quantity(v, num))
                    return Variant();
                return Variant(-num);
            case Type.not:
                auto val = as_bool(left.evaluate(ctx));
                if (val < 0)
                    return Variant();
                return Variant(!val);
            case Type.idx:
                assert(false, "TODO: index operator (array/map lookup)");
            case Type.call:
                // find function
                assert(left.flags & Flags.identifier, "Invalid function identifier");
                const(char)[] name = left.get_str();

                IntrinsicFunction* intrinsic;
                Expression* expr;

                intrinsic = name[] in g_app.intrinsic_functions;
                if (!intrinsic)
                    expr = null; // TODO: runtime function lookup...

                if (!intrinsic && !expr)
                    return Variant(null);

                // gather args
                Variant[16] args;
                size_t i = args.length - 1;
                const(Expression)* r = right;
                while (r)
                {
                    if (r.ty == Type.exp_list)
                    {
                        args[i--] = r.right.evaluate(ctx);
                        r = r.left;
                    }
                    else
                    {
                        args[i] = r.evaluate(ctx);
                        r = null;
                    }
                }

                // execute
                Variant result;
                if (intrinsic)
                    result = (*intrinsic)(args[i .. $]);
                else if (expr)
                {
                    // set the args to a local context and evaluate the expression...
                    assert(false, "TODO");
                }
                return result;
            case Type.cat:
                Variant l = left.evaluate(ctx);
                Variant r = right.evaluate(ctx);
                const(char)[] s = tconcat(l, r); // TODO: tconcat has a max str length...
                return Variant(s);
            case Type.or:
            case Type.and:
                bool l = left.evaluate(ctx).asBool();
                bool r = right.evaluate(ctx).asBool();
                return Variant(ty == Type.or ? l || r : l && r);
            case Type.eq:
            case Type.ne:
                Variant l = left.evaluate(ctx);
                Variant r = right.evaluate(ctx);
                bool cmp = l == r;
                return Variant(ty == Type.eq ? cmp : !cmp);
            case Type.lt:
            case Type.le:
                Variant l = left.evaluate(ctx);
                Variant r = right.evaluate(ctx);
                return Variant(ty == Type.lt ? l < r : l <= r);
            case Type.add:
            case Type.sub:
            case Type.mul:
            case Type.div:
                Variant lv = left.evaluate(ctx);
                Variant rv = right.evaluate(ctx);
                VarQuantity l, r;
                if (lv.isQuantity)
                    l = lv.asQuantity;
                else if (!as_quantity(lv, l))
                    return Variant();
                if (rv.isQuantity)
                    r = rv.asQuantity;
                else if (!as_quantity(rv, r))
                    return Variant();
                // guard the quantity op preconditions: bad units are a null result, not an assert
                if (ty == Type.add || ty == Type.sub)
                {
                    if (!l.isCompatible(r))
                        return Variant();
                }
                else if (ty == Type.mul ? !l.unit.can_combine!"*"(r.unit)
                                        : !l.unit.can_combine!"/"(r.unit))
                    return Variant();
                switch (ty)
                {
                    case Type.add: return Variant(l + r);
                    case Type.sub: return Variant(l - r);
                    case Type.mul: return Variant(l * r);
                    case Type.div: return Variant(l / r);
                    default: assert(false);
                }
        }
    }

    // an expression's format is its type-mode evaluation: element refs stand in as format
    // exemplars and the ordinary evaluator computes the result shape, so inference can never
    // drift from evaluation semantics
    FormatId infer_format(ref EvalContext ctx) const
    {
        import manager;
        import manager.element;
        import manager.series;

        if (ty == Type.elem)
        {
            // a bare reference aliases the element's exact format
            const(char)[] id = get_str();
            bool absolute = id.length > 0 && id[0] == '.';
            if (absolute)
                id = id[1 .. $];
            Element* e = (!absolute && ctx.root) ? ctx.root.find_element(id)
                                                 : g_app.find_element(id);
            return e ? e.format : FormatId.invalid;
        }

        bool saved = ctx.types_only;
        ctx.types_only = true;
        scope(exit) ctx.types_only = saved;
        Variant value = evaluate(ctx);
        return value.isNull ? FormatId.invalid : register_value_format(value);
    }

private:

    // data...
    Type ty;
    ubyte flags;

    struct CmdList
    {
        Array!ScriptCommand list;
        const(char)[] source;       // original block body text, between { } or [ ]
    }

    union
    {
        const(char)[] s = null;
        VarQuantity f;

        // allocated types; require destruction...
        struct
        {
            Expression* left;
            Expression* right;
        }

        MutableString!0 str;
        Array!(Expression*) arr;
        CmdList cmds;

        size_t[3] _reserve;
    }

    void gather_elements(ref Array!(const(char)[]) elements, ref bool has_var_ref) const
    {
        switch (ty)
        {
            case Type.elem:
                const(char)[] e = get_str();
                if (!elements[].contains(e))
                    elements ~= e;
                break;
            case Type.var:
                has_var_ref = true;
                break;
            case Type.arr:
                foreach (e; arr)
                    e.gather_elements(elements, has_var_ref);
                break;
            case Type.call:
                right.gather_elements(elements, has_var_ref);
                break;
            case Type.neg, Type.not:
                left.gather_elements(elements, has_var_ref);
                break;
            case Type.exp_list, Type.idx, Type.cat, Type.or, Type.and, Type.eq, Type.ne, Type.lt, Type.le, Type.add, Type.sub, Type.mul, Type.div:
                left.gather_elements(elements, has_var_ref);
                right.gather_elements(elements, has_var_ref);
                break;
            default:
                break;
        }
    }
}

class SyntaxError : Exception
{
    const(char)[] message;

    this(const(char)[] message) nothrow @nogc
    {
        this.message = message;
        super(cast(string)message);
    }
}

noreturn syntax_error(Args...)(auto ref Args args)
{
    throw tempAllocator().allocT!SyntaxError(tconcat(forward!args));
}

void skip_whitespace(ref const(char)[] text) nothrow
{
    while (text.length > 0)
    {
        if (text[0].is_space)
            text = text[1..$];
        else
        {
            if (text[0] == '#')
                while (text.length > 0 && text[0] != '\n' && text[0] != '\r')
                    text = text[1..$];
            break;
        }
    }
}

void skip_whitespace_and_newlines(ref const(char)[] text) nothrow
{
    while (text.length > 0)
    {
        if (text[0].is_whitespace)
            text = text[1..$];
        else if (text[0] == '#')
        {
            while (text.length > 0 && text[0] != '\n' && text[0] != '\r')
                text = text[1..$];
        }
        else
            break;
    }
}

bool match(bool take = true)(ref const(char)[] text, char c) nothrow
{
    if (text.length == 0 || text[0] != c)
        return false;
    static if (take)
        text = text[1..$];
    return true;
}

bool match(bool take = true)(ref const(char)[] text, const(char)[] s)
{
    if (text.length < s.length || text[0 .. s.length] != s)
        return false;
    static if (take)
        text = text[s.length .. $];
    return true;
}

void expect(ref const(char)[] text, char expected)
{
    if (!text.match(expected))
        syntax_error("Expected '", expected, "'");
}

Expression* alloc_expression(Args...)(auto ref Args args) nothrow
    => defaultAllocator().allocT!Expression(forward!args);

void free_expression(Expression* exp) nothrow
{
    defaultAllocator().freeT(exp);
}


Array!ScriptCommand parse_commands(ref const(char)[] text)
{
    version (ExpressionDebug)
        writeDebug("PARSE: ", text);

    Array!ScriptCommand commands;
    while (text.length > 0)
    {
        skip_whitespace_and_newlines(text);
        if (text.length == 0 || text[0] == ']' || text[0] == '}')
            break;
        commands ~= parse_command(text);
        skip_whitespace(text);
        if (text.length > 0)
        {
            if (text[0] == ']' || text[0] == '}')
                break;
            if (text[0] == ';' || text[0].is_newline)
            {
                // CRLF is one separator
                if (text[0] == '\r' && text.length > 1 && text[1] == '\n')
                    text = text[2 .. $];
                else
                    text = text[1 .. $];
            }
            else // if (test[0] == invalid characters...)
            {
                assert(false, "TODO: what is the set of invalid characters here?");
            }
        }
    }
    return commands;
}

ScriptCommand parse_command(ref const(char)[] text)
{
    Expression* e = parse_primary_exp(text);

    if (e.ty != Type.str || !(e.flags & Flags.identifier))
        syntax_error("Invalid command");

    ScriptCommand c;
    c.command = e.get_str();

    // Path/command tokens split on '/' (scope descent); once the first '=' is seen we're
    // in the argument list, where '/' is a literal so device paths etc. survive unquoted.
    bool in_args = false;
    while (text.length > 0)
    {
        skip_whitespace(text);
        if (text.length == 0 || text[0].is_newline || text[0] == ';' || text[0] == '}' || text[0] == ']')
            break;

        ScriptCommand.Argument a = parse_argument(text, in_args);
        if (a.name)
            c.named_args ~= a;
        else
            c.args ~= a.value;
    }

    return c;
}

ScriptCommand.Argument parse_argument(ref const(char)[] text, ref bool in_args)
{
    ScriptCommand.Argument a;

    static parse_arg_element(ref const(char)[] text, bool allow_slash)
    {
        Array!(Expression*) arr;
        Expression* arg;
        while (true)
        {
            arg = parse_primary_exp(text, allow_slash);
            if (text.length == 0 || text[0] != ',')
                break;

            // append to array and take next token...
            arr ~= arg;
            text = text[1 .. $];
            version (ExpressionDebug)
                writeDebug(",");
        }
        if (arr.length > 0)
        {
            arr ~= arg;
            arg = alloc_expression(Type.arr);
            arr.moveEmplace(arg.arr);
        }
        return arg;
    }

    Expression* arg = parse_arg_element(text, in_args);
    if (text.length > 0 && text[0] == '=')
    {
        if (arg.ty != Type.str || !(arg.flags & Flags.identifier))
            syntax_error("Expected identifier left of '='");
        text = text[1 .. $];
        in_args = true;
        a.value = parse_arg_element(text, true);
        a.name = arg;
    }
    else
        a.value = arg;
    return a;
}

alias parse_expression = parse_logical_or_exp;

Expression* parse_logical_or_exp(ref const(char)[] text)
{
    Expression* left = parse_logical_and_exp(text);
    scope(failure) free_expression(left);
    skip_whitespace(text);
    while (text.match("||"))
    {
        version (ExpressionDebug)
            writeDebug("OR");
        skip_whitespace(text);
        Expression* right = parse_logical_and_exp(text);
        left = try_fold(Type.or, left, right);
        skip_whitespace(text);
    }
    return left;
}

Expression* parse_logical_and_exp(ref const(char)[] text)
{
    Expression* left = parse_equality_exp(text);
    scope(failure) free_expression(left);
    skip_whitespace(text);
    while (text.match("&&"))
    {
        version (ExpressionDebug)
            writeDebug("AND");
        skip_whitespace(text);
        Expression* right = parse_equality_exp(text);
        left = try_fold(Type.and, left, right);
        skip_whitespace(text);
    }
    return left;
}

Expression* parse_equality_exp(ref const(char)[] text)
{
    Expression* left = parse_relational_exp(text);
    scope(failure) free_expression(left);
    skip_whitespace(text);
    while (text.match("==") || text.match("!="))
    {
        version (ExpressionDebug)
            writeDebug("EQ");
        Type ty = text.ptr[-1] == '=' ? Type.eq : Type.ne;
        skip_whitespace(text);
        Expression* right = parse_relational_exp(text);
        left = try_fold(ty, left, right);
        skip_whitespace(text);
    }
    return left;
}

Expression* parse_relational_exp(ref const(char)[] text)
{
    Expression* left = parse_concat_exp(text);
    scope(failure) free_expression(left);
    skip_whitespace(text);
    while (text.match('<') || text.match("<=") || text.match('>') || text.match(">="))
    {
        version (ExpressionDebug)
            writeDebug("REL");
        Type ty = text.ptr[-1] == '=' ? Type.le : Type.lt;
        bool swap = text.ptr[text.ptr[-1] == '=' ? -2 : -1] == '>';
        skip_whitespace(text);
        Expression* right = parse_concat_exp(text);
        left = try_fold(ty, swap ? right : left, swap ? left : right);
        skip_whitespace(text);
    }
    return left;
}

Expression* parse_concat_exp(ref const(char)[] text)
{
    Expression* left = parse_additive_exp(text);
    scope(failure) free_expression(left);
    skip_whitespace(text);
    while (text.match(".."))
    {
        version (ExpressionDebug)
            writeDebug("CAT");
        skip_whitespace(text);
        Expression* right = parse_additive_exp(text);
        left = try_fold(Type.cat, left, right);
        skip_whitespace(text);
    }
    return left;
}

Expression* parse_additive_exp(ref const(char)[] text)
{
    Expression* left = parse_multiplicative_exp(text);
    scope(failure) free_expression(left);
    skip_whitespace(text);
    while (text.match('+') || text.match('-'))
    {
        version (ExpressionDebug)
            writeDebug("ADD");
        Type ty = text.ptr[-1] == '+' ? Type.add : Type.sub;
        skip_whitespace(text);
        Expression* right = parse_multiplicative_exp(text);
        left = try_fold(ty, left, right);
        skip_whitespace(text);
    }
    return left;
}

Expression* parse_multiplicative_exp(ref const(char)[] text)
{
    Expression* left = parse_unary_exp(text);
    scope(failure) free_expression(left);
    skip_whitespace(text);
    while (text.match('*') || text.match('/'))
    {
        version (ExpressionDebug)
            writeDebug("MUL");
        Type ty = text.ptr[-1] == '*' ? Type.mul : Type.div;
        skip_whitespace(text);
        Expression* right = parse_unary_exp(text);
        left = try_fold(ty, left, right);
        skip_whitespace(text);
    }
    return left;
}

Expression* parse_unary_exp(ref const(char)[] text)
{
    if (text.match('-') || text.match('!') || text.match('+'))
    {
        version (ExpressionDebug)
            writeDebug("UNARY");
        char op = text.ptr[-1];
        Expression* expr = parse_unary_exp(text);
        if (op == '+')
            return expr;
        Type ty = op ? Type.neg : Type.not;
        return try_fold(ty, expr, null);
    }
    return parse_postfix_exp(text);
}

Expression* parse_postfix_exp(ref const(char)[] text)
{
    Expression* left = parse_primary_exp(text);
    scope(failure) free_expression(left);
    while (text.match('(') || text.match('['))
    {
        bool call = text.ptr[-1] == '(';
        version (ExpressionDebug)
            writeDebug(call ? "CALL (" : "IDX [");
        Expression* right;
        scope(failure) if (right) free_expression(right);
        do
        {
            skip_whitespace(text);
            Expression* expr = parse_expression(text);

            if (!right)
                right = expr;
            else
            {
                Expression* list = alloc_expression(Type.exp_list);
                list.left = right;
                list.right = expr;
                right = list;
            }
            skip_whitespace(text);
        }
        while (text.match(','));

        if (call)
            text.expect(')');
        else
            text.expect(']');
        version (ExpressionDebug)
            writeDebug(call ? "CALL ]" : "IDX ]");
        left = try_fold(call ? Type.call : Type.idx, left, right);
    }
    return left;
}

Expression* parse_primary_exp(ref const(char)[] text, bool allow_slash = false)
{
    if (text.length == 0)
        syntax_error("Expected expression");

    Expression* r;

    // parse paren-enclosed expression
    if (text.match('('))
    {
        version (ExpressionDebug)
            writeDebug("PAREN (");
        skip_whitespace(text);
        Expression* expr = parse_expression(text);
        scope(failure) free_expression(expr);
        skip_whitespace(text);
        text.expect(')');
        version (ExpressionDebug)
            writeDebug("PAREN )");
        return expr;
    }

    // parse command blocks
    if (text.match('[') || text.match('{'))
    {
        bool eval = text.ptr[-1] == '[';
        const(char)* body_start = text.ptr;
        Array!ScriptCommand commands = parse_commands(text);
        const(char)[] body = body_start[0 .. text.ptr - body_start].trim;
        if (eval)
            text.expect(']');
        else
            text.expect('}');
        Expression* cmds = alloc_expression(Type.cmd_list);
        commands.moveEmplace(cmds.cmds.list);
        cmds.cmds.source = body;
        if (eval)
            cmds.flags |= Flags.command_eval;
        return cmds;
    }

    // parse quoted string
    if (text.match('"'))
    {
        MutableString!0 copy;
        bool interpolated = false;

        size_t len = 0;
        while (len < text.length && text[len] != '"')
        {
            if (text[len] == '\\')
            {
                if (++len == text.length)
                    syntax_error("Expected '\"'");
                copy = text[0 .. len - 1];
            }
            if (text[len] == '$')
                interpolated = true;
            if (copy)
                copy ~= text[len];
            len++;
        }
        if (len == text.length)
            syntax_error("Expected '\"'");

        if (copy)
            r = alloc_expression(copy.move);
        else
        {
            r = alloc_expression(Type.str);
            r.s = text[0 .. len];
        }
        r.flags |= Flags.constant;
        if (interpolated)
            r.flags |= Flags.interpolated_string;

        text = text[len + 1 .. $];
        return r;
    }

    // parse unquoted strings, numbers, maybe even lists...

    // parse string...
    bool is_var = text[0] == '$';
    bool is_element = text[0] == '@';
    bool identifier;

    if (is_var || is_element)
    {
        text = text[1 .. $];

        if (text.length == 0 || text[0] == '/')
            syntax_error("Invalid ", is_var ? "variable" : "element", " name");
    }

    identifier = text[0].is_alpha || text[0] == '_' || text[0] == '/' || text[0] == ':' || (is_element && text[0] == '.');

    string string_delimiters = "/$=,;\"\\{}[]()?'`";
    size_t len = identifier; // skip the first char; first char has some special cases
    scan_string: while (len < text.length)
    {
        char c = text[len];
        if (c <= ' ' || c >= 0x7F) // only ascii characters
            break;
        // TODO: use a lookup table?
        foreach (d; string_delimiters)
        {
            if (c == d)
            {
                if (allow_slash && c == '/')
                    break;      // in argument-value context '/' is a literal (e.g. device paths)
                break scan_string;
            }
        }

        if (identifier && !c.is_alpha_numeric && c != '_' && c != '-' && c != '.')
        {
            if (is_var || is_element)
                break;
            identifier = false;
        }
        ++len;
    }

    // validate the string...
    if (len < text.length)
    {
        // string should have terminated on a valid delimiter
        if (!text[len].is_whitespace && text[len] != '=' && text[len] != '/' && text[len] != ';' && text[len] != ',' && text[len] != ')' && text[len] != '}' && text[len] != ']' && !(is_var && text[len] == '('))
            syntax_error("Invalid token");
    }

    const(char)[] token = text[0 .. len];
    if (!is_var && !is_element && token == "null")
    {
        r = alloc_expression(Type.null_);
        r.flags = Flags.constant;
    }
    else
    {
        size_t taken = 0;
        VarQuantity q = token.parse_quantity(&taken);
        if (taken == len)
        {
            // we parsed a number!
            r = alloc_expression(Type.num);
            r.flags = Flags.constant;
            r.f = q;

            version (ExpressionDebug)
                writeDebug("NUM: ", r.f);
        }
        else
        {
            if ((is_var || is_element) && !identifier)
                syntax_error("Expected identifier");
            r = alloc_expression(is_var ? Type.var : is_element ? Type.elem : Type.str);
            r.flags = Flags.no_quotes;
            if (identifier)
                r.flags |= Flags.identifier;
            r.s = token;

            version (ExpressionDebug)
                writeDebug(is_var ? "VAR: " : is_element ? "ELEMENT: " : "STR: ", r.get_str());
        }
    }
    text = text[len .. $];

    return r;
}

Expression* try_fold(Type ty, Expression* l, Expression* r)
{
    Expression* exp = fold(ty, l, r);
    if (exp)
    {
        // left was recycled...
        if (r)
            free_expression(r);
    }
    else
    {
        exp = alloc_expression(ty);
        exp.left = l;
        exp.right = r;
    }
    return exp;
}

Expression* fold(Type ty, Expression* l, Expression* r)
{
    // attempt constant folding...

    if (ty == Type.call)
        return null;

    // can only fold if both sides are constant...
    if (l.ty == Type.null_ || (r && r.ty == Type.null_))
        return null;
    if (l.ty >= Type.var || (ty >= Type.idx && r.ty >= Type.var))
        return null;

    // result will overwrite and return `l`
    // caller is responsible for destroying `r` if not null

    switch (ty)
    {
        case Type.not:
            bool lb = l.as_bool;
            *l = Expression(Type.num);
            l.f = VarQuantity(!lb);
            return l;

        case Type.neg:
            VarQuantity lf = l.as_num;
            *l = Expression(Type.num);
            l.f = -lf;
            return l;

        case Type.cat:
            MutableString!0 s;
            if (l.ty == Type.str)
                s = l.get_str;
            else
                s ~= l.as_num;
            if (r.ty == Type.str)
                s ~= r.get_str;
            else
                s ~= r.as_num;
            *l = Expression(s.move);
            return l;

        case Type.or:
        case Type.and:
            bool ltrue = l.as_bool;
            bool rtrue = r.as_bool;
            *l = Expression(Type.num);
            l.f = VarQuantity(ty == Type.or ? ltrue || rtrue : ltrue && rtrue);
            return l;

        case Type.eq:
        case Type.ne:
        case Type.lt:
        case Type.le:
            if (l.ty == Type.str && r.ty == Type.str)
            {
                // string comparison
                ptrdiff_t t = l.get_str().cmp(r.get_str());
                *l = Expression(Type.num);
                l.f = VarQuantity(ty == Type.eq ? t == 0 :
                                  ty == Type.ne ? t != 0 :
                                  ty == Type.lt ? t <  0 :
                                                  t <= 0);
                return l;
            }
            goto case;

        case Type.add:
        case Type.sub:
        case Type.mul:
        case Type.div:
            VarQuantity lf = l.as_num;
            VarQuantity rf = r.as_num;
            *l = Expression(Type.num);
            switch (ty)
            {
                case Type.eq: l.f = VarQuantity(lf == rf); break;
                case Type.ne: l.f = VarQuantity(lf != rf); break;
                case Type.lt: l.f = VarQuantity(lf <  rf); break;
                case Type.le: l.f = VarQuantity(lf <= rf); break;
                case Type.add: l.f = lf + rf; break;
                case Type.sub: l.f = lf - rf; break;
                case Type.mul: l.f = lf * rf; break;
                case Type.div: l.f = lf / rf; break;
                default: assert(0); // unreachable
            }
            return l;

        default:
            return null;
    }
}


unittest
{
    logLevel = Level.Debug;

    const(char)[] text = "$a .. 10 + (-10.2 * 2 / --3) .. (\"wow\" .. \"wee\")";
    Expression* e = parse_expression(text);
    assert(text.length == 0);

    // {...} captures source and produces a Script Variant on evaluation
    text = "{ /print hello }";
    e = parse_primary_exp(text);
    assert(e.ty == Type.cmd_list);
    assert((e.flags & Flags.command_eval) == 0);
    assert(e.cmd_list_source() == "/print hello");

    EvalContext ctx;
    Variant v = e.evaluate(ctx);
    assert(v.isUser!Script);

    Script sb = v.asUser!Script;
    assert(!sb.empty);
    assert(sb.commands.length == 1);
    assert(sb.commands[0].command == "/print");

    // [...] sets command_eval flag; eval returns null without sub_results stash
    text = "[ /sys/sysinfo ]";
    e = parse_primary_exp(text);
    assert(e.ty == Type.cmd_list);
    assert((e.flags & Flags.command_eval) != 0);

    v = e.evaluate(ctx);
    assert(v.isNull);

    // `:`-prefixed identifiers parse as command names; named args use `key=value` (no spaces)
    text = ":set x=5";
    Array!ScriptCommand cmds = parse_commands(text);
    assert(cmds.length == 1);
    assert(cmds[0].command == ":set");
    assert(cmds[0].named_args.length == 1);
    assert(cmds[0].named_args[0].name.get_str() == "x");

    // path/command tokens split on '/', but an argument value keeps '/' literal (device paths)
    text = "/stream/serial/add name=com3 device=/dev/ttyUSB0";
    cmds = parse_commands(text);
    assert(cmds.length == 1);
    assert(cmds[0].command == "/stream");
    assert(cmds[0].args.length == 2);           // /serial /add resolve as scope descent
    assert(cmds[0].args[0].get_str() == "/serial");
    assert(cmds[0].args[1].get_str() == "/add");
    assert(cmds[0].named_args.length == 2);
    assert(cmds[0].named_args[1].name.get_str() == "device");
    assert(cmds[0].named_args[1].value.get_str() == "/dev/ttyUSB0");
}
