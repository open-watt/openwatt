module manager.expression;

import urt.array;
import urt.conv;
import urt.log;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.string;

public import urt.variant;

//version = ExpressionDebug;

@nogc:


enum Type : ubyte
{
    // primary
    str = 0,
    num,
    var,
    arr,

    // lists
    cmd_list,

    // unary
    neg,
    not,

    // postfix
    idx,

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
    mod,
}

enum Flags : ubyte
{
    identifier = 1 << 0,
    interpolated_string = 1 << 1,
    command_eval = 1 << 2,
    constant = 1 << 3,
    no_quotes = 1 << 4,
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
        this.value = Variant(forward!value);
    }

    const(char)[] name;
    Variant value;
}

struct Context
{
nothrow @nogc:

    Session session;
    Scope root;

    Array!ScriptCommand script;

    // TODO: local variables...

    int command; // which command are we currently working on? (TODO: and which sub-command? like `[ cmd ]` arguments)
    CommandState state;

    import manager.console;
    CommandState execute(Session session, Scope scope_)
    {
        if (script.length == 0)
            return null;

        Array!Variant vars;
        Array!NamedArgument namedVars;

        vars ~= Variant(script[0].command);
        foreach (ref arg; script[0].args)
            vars ~= arg.evaluate();
        foreach (ref arg; script[0].named_args)
            namedVars ~= NamedArgument(arg.name.get_str(), arg.value.evaluate());
        return scope_.execute(session, vars[], namedVars[]);
    }
}

struct ScriptCommand
{
    const(char)[] command;
    Array!(Expression*) args;
    Array!Argument named_args;

private:
    struct Argument
    {
        Expression* name;
        Expression* value;
    }
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
        flags = 0; // TODO: we might need to scan for variable references...
        new(str) typeof(str)(forward!s);
    }

    ~this()
    {
        // strings with pointer and zero length are actually a `String` and that needs to be destroyed
        if (is_string())
            str.destroy!false();
        else if (ty == Type.arr)
            arr.destroy!false();
        else if (ty == Type.cmd_list)
            cmds.destroy!false();
        else if (ty >= Type.neg)
        {
            left.freeExpression();
            if (ty >= Type.idx)
                right.freeExpression();
        }
    }

    // HACK: the copy assignment actually moves for now (!!)
    void opAssign(ref Expression e)// @disable; // only accept move's...
//    void opAssign(Expression e)
    {
        this.destroy!false();
        ty = e.ty;
        flags = e.flags;
        s = e.s; // this copies the largest type
        e.s = null;
    }

    void opAssign(S : String)(auto ref S s)
    {
        this.destroy!false();
        ty = Type.str;
        flags = 0; // TODO: we might need to scan for variable references...
        new(str) typeof(str)(forward!s);
        s.length = 0;
    }

    bool is_string() const
        => (ty == Type.str || ty == Type.var) && s.length == 0 && s.ptr !is null;

    bool as_bool() const
    {
        switch (ty)
        {
            case Type.num: return f != 0;
            case Type.str: return get_str().length != 0;
            default:
                // this is just for getting constants; we don't do expression evaluation here...
                assert(false);
        }
    }

    double as_num() const
    {
        switch (ty)
        {
            case Type.num: return f;
            case Type.str:
                size_t taken;
                double d = get_str().parse_float(&taken);
                if (taken != s.length)
                    return 0;
                return d;
            default:
                // this is just for getting constants; we don't do expression evaluation here...
                assert(false);
        }
    }

    const(char)[] get_str() const
    {
        if (ty == Type.str || ty == Type.var)
            return (s.length == 0 && s.ptr !is null) ? str[] : s;
        assert(false);
    }

    Variant evaluate() const
    {
        static bool as_bool(Variant v)
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
            assert(false, "TODO: what is this? should it convert to a boolean?");
        }

        static double as_number(Variant v)
        {
            if (v.isNumber)
                return v.asDouble;
            if (v.isString)
            {
                size_t taken;
                double d = v.asString.parse_float(&taken);
                if (taken != v.asString.length)
                    return 0;
                return d;
            }
            assert(false, "TODO: what is this? should it convert to a number?");
        }

        final switch (ty)
        {
            case Type.num:
                return Variant(f);
            case Type.str:
                return Variant(get_str());
            case Type.var:
                assert(false, "TODO: lookup variable...");
            case Type.arr:
                Variant r;
                ref Array!Variant va = r.asArray();
                foreach (e; arr)
                    va ~= e.evaluate();
                return r.move;
            case Type.cmd_list:
                assert(false, "TODO: how do we shuttle this value into commands? in a variant? some other way?");
            case Type.neg:
                return Variant(-as_number(left.evaluate()));
            case Type.not:
                return Variant(!as_bool(left.evaluate()));
            case Type.idx:
                assert(false, "TODO: index operator (array/map lookup)");
            case Type.cat:
                Variant l = left.evaluate();
                Variant r = right.evaluate();
                const(char)[] s = tconcat(l, r); // TODO: tconcat has a max str length...
                return Variant(s);
            case Type.or:
            case Type.and:
                bool l = left.evaluate().asBool();
                bool r = right.evaluate().asBool();
                return Variant(ty == Type.or ? l || r : l && r);
            case Type.eq:
            case Type.ne:
                assert(false, "TODO: equality operators");
            case Type.lt:
            case Type.le:
                assert(false, "TODO: comparison operators");
            case Type.add:
            case Type.sub:
            case Type.mul:
            case Type.div:
            case Type.mod:
                double l = as_number(left.evaluate());
                double r = as_number(right.evaluate());
                switch (ty)
                {
                    case Type.add: return Variant(l + r);
                    case Type.sub: return Variant(l - r);
                    case Type.mul: return Variant(l * r);
                    case Type.div: return Variant(l / r);
                    case Type.mod: return Variant(l % r);
                    default: assert(false);
                }
        }
    }

    // data...
    Type ty;
    ubyte flags;

    union
    {
        const(char)[] s = null;
        double f;

        // allocated types; require destruction...
        struct
        {
            Expression* left;
            Expression* right;
        }

        MutableString!0 str;
        Array!(Expression*) arr;
        Array!ScriptCommand cmds;
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

noreturn syntaxError(Args...)(auto ref Args args)
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
                while (text.length > 0 && (text[0] != '\n' || (text[0] != '\r' && text.length > 1 && text[1] != 'n')))
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
            while (text.length > 0 && (text[0] != '\n' || (text[0] != '\r' && text.length > 1 && text[1] != 'n')))
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
        syntaxError("Expected '", expected, "'");
}

Expression* alloc_expression(Args...)(auto ref Args args) nothrow
    => defaultAllocator().allocT!Expression(forward!args);

void freeExpression(Expression* exp) nothrow
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
            if (text[0] == ';' ||  text[0].is_newline)
            {
                if (text[0] == '\r' && text.length == 1 || text[1] != '\n')
                    assert(false); // TODO: not actually a newline; need to continue looking for semicolon or newlines...
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
        syntaxError("Invalid command");

    ScriptCommand c;
    c.command = e.get_str();

    while (text.length > 0)
    {
        skip_whitespace(text);
        if (text.length == 0 || text[0].is_newline || text[0] == ';' || text[0] == '}' || text[0] == ']')
            break;

        ScriptCommand.Argument a = parse_argument(text);
        if (a.name)
            c.named_args ~= a;
        else
            c.args ~= a.value;
    }

    return c;
}

ScriptCommand.Argument parse_argument(ref const(char)[] text)
{
    ScriptCommand.Argument a;
    Expression* arg = parse_primary_exp(text);
    if (text.length > 0 && text[0] == '=')
    {
        if (arg.ty != Type.str || !(arg.flags & Flags.identifier))
            syntaxError("Expected identifier left of '='");
        text = text[1 .. $];
        a.value = parse_primary_exp(text);
        a.name = arg;
    }
    else
        a.value = arg;
    return a;
}

alias parseExpression = parse_logical_or_exp;

Expression* parse_logical_or_exp(ref const(char)[] text)
{
    Expression* left = parse_logical_and_exp(text);
    scope(failure) freeExpression(left);
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
    scope(failure) freeExpression(left);
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
    scope(failure) freeExpression(left);
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
    scope(failure) freeExpression(left);
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
    scope(failure) freeExpression(left);
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
    scope(failure) freeExpression(left);
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
    scope(failure) freeExpression(left);
    skip_whitespace(text);
    while (text.match('*') || text.match('/') || text.match('%'))
    {
        version (ExpressionDebug)
            writeDebug("MUL");
        Type ty = text.ptr[-1] == '*' ? Type.mul : text.ptr[-1] == '/' ? Type.div : Type.mod;
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
    scope(failure) freeExpression(left);
    while (text.match('['))
    {
        version (ExpressionDebug)
            writeDebug("IDX [");
        skip_whitespace(text);
        Expression* expr = parseExpression(text);
        scope(failure) freeExpression(expr);
        skip_whitespace(text);
        text.expect(']');
        version (ExpressionDebug)
            writeDebug("IDX ]");
        left = try_fold(Type.idx, left, expr);
    }
    return left;
}

Expression* parse_primary_exp(ref const(char)[] text)
{
    if (text.length == 0)
        syntaxError("Expected expression");

    // parse paren-enclosed expression
    if (text.match('('))
    {
        version (ExpressionDebug)
            writeDebug("PAREN (");
        skip_whitespace(text);
        Expression* expr = parseExpression(text);
        scope(failure) freeExpression(expr);
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
        Array!ScriptCommand commands = parse_commands(text);
        if (eval)
            text.expect(']');
        else
            text.expect('}');
        Expression* cmds = alloc_expression(Type.cmd_list);
        commands.moveEmplace(cmds.cmds);
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
                    syntaxError("Expected '\"'");
                copy = text[0 .. len - 1];
            }
            if (text[len] == '$')
                interpolated = true;
            if (copy)
                copy ~= text[len];
            len++;
        }
        if (len == text.length)
            syntaxError("Expected '\"'");

        Expression* r;
        if (copy)
            r = alloc_expression(copy.move);
        else
        {
            r = alloc_expression(Type.str);
            r.s = text[0 .. len];
        }
        r.flags = Flags.constant;
        if (interpolated)
            r.flags |= Flags.interpolated_string;

        text = text[len + 1 .. $];
        return r;
    }

    Array!(Expression*) arr;
    Expression* r;

    // parse unquoted strings, numbers, maybe even lists...
    while (true)
    {
        // parse string...
        bool isVar = text[0] == '$';
        bool identifier;
        bool numeric;
        int numDots = 0;

        if (isVar)
        {
            text = text[1 .. $];

            if (text.length == 0 || text[0] == '/')
                syntaxError("Invalid variable name");
        }

        identifier = text[0].is_alpha || text[0] == '_' || text[0] == '/';
        if (!identifier)
            numeric = text[0].is_numeric || (!isVar && (text[0] == '-' || text[0] == '+') && text.length > 1 && text[1].is_numeric);

        string stringDelimiters = "/$=,;\"\\{}[]()?'`";
        size_t len = identifier | numeric; // skip the first char; first char has some special cases
        scan_string: while (len < text.length)
        {
            char c = text[len];
            if (c <= ' ' || c >= 0x7F) // only ascii characters
                break;
            // TODO: use a lookup table?
            foreach (d; stringDelimiters)
            {
                if (c == d)
                    break scan_string;
            }

            if (identifier && !c.is_alpha_numeric && c != '_' && c != '-')
            {
                if (isVar)
                    break;
                identifier = false;
            }
            else if (numeric && !c.is_numeric)
            {
                if (isVar)
                    break;
                if (c == '.')
                    ++numDots;
                else
                    numeric = false;
            }
            ++len;
        }

        // validate the string...
        if (len < text.length)
        {
            // string should have terminated on a valid delimiter
            if (!text[len].is_whitespace && text[len] != '=' && text[len] != '/' && text[len] != ';' && text[len] != ',' && text[len] != ')' && text[len] != '}' && text[len] != ']')
                syntaxError("Invalid token");
        }

        if (numeric && numDots <= 1)
        {
            size_t taken = 0;
            double f = text.parse_float(&taken);
            if (taken == 0)
                syntaxError("Expected number");
            else
                text = text[taken .. $];
            r = alloc_expression(Type.num);
            r.flags = Flags.constant;
            r.f = f;

            version (ExpressionDebug)
                writeDebug("NUM: ", r.f);
        }
        else
        {
            if (isVar && !identifier && !numeric)
                syntaxError("Expected identifier");
            r = alloc_expression(isVar ? Type.var : Type.str);
            r.flags = Flags.no_quotes;
            if (identifier)
                r.flags |= Flags.identifier;
            r.s = text[0 .. len];
            text = text[len .. $];

            version (ExpressionDebug)
                writeDebug(isVar ? "VAR: " : "STR: ", r.s);
        }

        if (text.length == 0 || text[0] != ',')
            break;

        // append to array and take next token...
        arr ~= r;
        text = text[1 .. $];
        version (ExpressionDebug)
            writeDebug(",");
    }

    if (arr.length > 0)
    {
        arr ~= r;
        r = alloc_expression(Type.arr);
        arr.moveEmplace(r.arr);
    }

    return r;
}


Expression* try_fold(Type ty, Expression* l, Expression* r)
{
    Expression* exp = fold(ty, l, r);
    if (exp)
    {
        // left was recycled...
        if (r)
            freeExpression(r);
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

    // can only fold if both sides are constant...
    if (l.ty >= Type.var || (ty >= Type.idx && r.ty >= Type.var))
        return null;

    // result will overwrite and return `l`
    // caller is responsible for destroying `r` if not null

    switch (ty)
    {
        case Type.not:
            bool lb = l.as_bool;
            *l = Expression(Type.num);
            l.f = !lb;
            return l;

        case Type.neg:
            double lf = l.as_num;
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
            l.f = ty == Type.or ? ltrue || rtrue : ltrue && rtrue;
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
                l.f = ty == Type.eq ? t == 0 :
                      ty == Type.ne ? t != 0 :
                      ty == Type.lt ? t < 0 :
                                      t <= 0;
                return l;
            }
            goto case;

        case Type.add:
        case Type.sub:
        case Type.mul:
        case Type.div:
        case Type.mod:
            double lf = l.as_num;
            double rf = r.as_num;
            *l = Expression(Type.num);
            switch (ty)
            {
                case Type.eq: l.f = lf == rf; break;
                case Type.ne: l.f = lf != rf; break;
                case Type.lt: l.f = lf < rf; break;
                case Type.le: l.f = lf <= rf; break;
                case Type.add: l.f = lf + rf; break;
                case Type.sub: l.f = lf - rf; break;
                case Type.mul: l.f = lf * rf; break;
                case Type.div: l.f = lf / rf; break;
                case Type.mod: l.f = lf % rf; break;
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
    Expression* e = parseExpression(text);
    assert(text.length == 0);

}
