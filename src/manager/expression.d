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
    Str = 0,
    Num,
    Var,
    Arr,

    // lists
    CmdList,

    // unary
    Neg,
    Not,

    // postfix
    Idx,

    // binary
    Or,
    And,
    Eq,
    Ne,
    Lt,
    Le,
    Cat,
    Add,
    Sub,
    Mul,
    Div,
    Mod,
}

enum Flags : ubyte
{
    Identifier = 1 << 0,
    InterpolatedString = 1 << 1,
    CommandEval = 1 << 2,
    Constant = 1 << 3,
    NoQuotes = 1 << 4,
}

struct NamedArgument
{
    this(ref NamedArgument rh) nothrow @nogc
    {
        name = rh.name;
        value = rh.value;
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
        foreach (ref arg; script[0].namedArgs)
            namedVars ~= NamedArgument(arg.name.getStr(), arg.value.evaluate());
        return scope_.execute(session, vars[], namedVars[]);
    }
}

struct ScriptCommand
{
    const(char)[] command;
    Array!(Expression*) args;
    Array!Argument namedArgs;

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
        ty = Type.Num;
        f = b ? 1 : 0;
    }

    this(S : MutableString!0)(auto ref S s)
    {
        ty = Type.Str;
        flags = 0; // TODO: we might need to scan for variable references...
        new(str) typeof(str)(forward!s);
    }

    ~this()
    {
        // strings with pointer and zero length are actually a `String` and that needs to be destroyed
        if (isString())
            str.destroy!false();
        else if (ty == Type.Arr)
            arr.destroy!false();
        else if (ty == Type.CmdList)
            cmds.destroy!false();
        else if (ty >= Type.Neg)
        {
            left.freeExpression();
            if (ty >= Type.Idx)
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
        ty = Type.Str;
        flags = 0; // TODO: we might need to scan for variable references...
        new(str) typeof(str)(forward!s);
        s.length = 0;
    }

    bool isString() const
        => (ty == Type.Str || ty == Type.Var) && s.length == 0 && s.ptr !is null;

    bool asBool() const
    {
        switch (ty)
        {
            case Type.Num: return f != 0;
            case Type.Str: return getStr().length != 0;
            default:
                // this is just for getting constants; we don't do expression evaluation here...
                assert(false);
        }
    }

    double asNum() const
    {
        switch (ty)
        {
            case Type.Num: return f;
            case Type.Str:
                size_t taken;
                double d = getStr().parse_float(&taken);
                if (taken != s.length)
                    return 0;
                return d;
            default:
                // this is just for getting constants; we don't do expression evaluation here...
                assert(false);
        }
    }

    const(char)[] getStr() const
    {
        if (ty == Type.Str || ty == Type.Var)
            return (s.length == 0 && s.ptr !is null) ? str[] : s;
        assert(false);
    }

    Variant evaluate() const
    {
        static bool asBool(Variant v)
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

        static double asNumber(Variant v)
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
            case Type.Num:
                return Variant(f);
            case Type.Str:
                return Variant(getStr());
            case Type.Var:
                assert(false, "TODO: lookup variable...");
            case Type.Arr:
                Variant r;
                ref Array!Variant va = r.asArray();
                foreach (e; arr)
                    va ~= e.evaluate();
                return r.move;
            case Type.CmdList:
                assert(false, "TODO: how do we shuttle this value into commands? in a variant? some other way?");
            case Type.Neg:
                return Variant(-asNumber(left.evaluate()));
            case Type.Not:
                return Variant(!asBool(left.evaluate()));
            case Type.Idx:
                assert(false, "TODO: index operator (array/map lookup)");
            case Type.Cat:
                Variant l = left.evaluate();
                Variant r = right.evaluate();
                const(char)[] s = tconcat(l, r); // TODO: tconcat has a max str length...
                return Variant(s);
            case Type.Or:
            case Type.And:
                bool l = left.evaluate().asBool();
                bool r = right.evaluate().asBool();
                return Variant(ty == Type.Or ? l || r : l && r);
            case Type.Eq:
            case Type.Ne:
                assert(false, "TODO: equality operators");
            case Type.Lt:
            case Type.Le:
                assert(false, "TODO: comparison operators");
            case Type.Add:
            case Type.Sub:
            case Type.Mul:
            case Type.Div:
            case Type.Mod:
                double l = asNumber(left.evaluate());
                double r = asNumber(right.evaluate());
                switch (ty)
                {
                    case Type.Add: return Variant(l + r);
                    case Type.Sub: return Variant(l - r);
                    case Type.Mul: return Variant(l * r);
                    case Type.Div: return Variant(l / r);
                    case Type.Mod: return Variant(l % r);
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

void skipWhitespace(ref const(char)[] text) nothrow
{
    while (text.length > 0)
    {
        if (text[0].isSpace)
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

void skipWhitespaceAndNewlines(ref const(char)[] text) nothrow
{
    while (text.length > 0)
    {
        if (text[0].isWhitespace)
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

Expression* allocExpression(Args...)(auto ref Args args) nothrow
    => defaultAllocator().allocT!Expression(forward!args);

void freeExpression(Expression* exp) nothrow
{
    defaultAllocator().freeT(exp);
}


Array!ScriptCommand parseCommands(ref const(char)[] text)
{
    version (ExpressionDebug)
        writeDebug("PARSE: ", text);

    Array!ScriptCommand commands;
    while (text.length > 0)
    {
        skipWhitespaceAndNewlines(text);
        if (text.length == 0 || text[0] == ']' || text[0] == '}')
            break;
        commands ~= parseCommand(text);
        skipWhitespace(text);
        if (text.length > 0)
        {
            if (text[0] == ';' ||  text[0].isNewline)
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

ScriptCommand parseCommand(ref const(char)[] text)
{
    Expression* e = parsePrimaryExp(text);

    if (e.ty != Type.Str || !(e.flags & Flags.Identifier))
        syntaxError("Invalid command");

    ScriptCommand c;
    c.command = e.getStr();

    while (text.length > 0)
    {
        skipWhitespace(text);
        if (text.length == 0 || text[0].isNewline || text[0] == ';' || text[0] == '}' || text[0] == ']')
            break;

        ScriptCommand.Argument a = parseArgument(text);
        if (a.name)
            c.namedArgs ~= a;
        else
            c.args ~= a.value;
    }

    return c;
}

ScriptCommand.Argument parseArgument(ref const(char)[] text)
{
    ScriptCommand.Argument a;
    Expression* arg = parsePrimaryExp(text);
    if (text.length > 0 && text[0] == '=')
    {
        if (arg.ty != Type.Str || !(arg.flags & Flags.Identifier))
            syntaxError("Expected identifier left of '='");
        text = text[1 .. $];
        a.value = parsePrimaryExp(text);
        a.name = arg;
    }
    else
        a.value = arg;
    return a;
}

alias parseExpression = parseLogicalOrExp;

Expression* parseLogicalOrExp(ref const(char)[] text)
{
    Expression* left = parseLogicalAndExp(text);
    scope(failure) freeExpression(left);
    skipWhitespace(text);
    while (text.match("||"))
    {
        version (ExpressionDebug)
            writeDebug("OR");
        skipWhitespace(text);
        Expression* right = parseLogicalAndExp(text);
        left = tryFold(Type.Or, left, right);
        skipWhitespace(text);
    }
    return left;
}

Expression* parseLogicalAndExp(ref const(char)[] text)
{
    Expression* left = parseEqualityExp(text);
    scope(failure) freeExpression(left);
    skipWhitespace(text);
    while (text.match("&&"))
    {
        version (ExpressionDebug)
            writeDebug("AND");
        skipWhitespace(text);
        Expression* right = parseEqualityExp(text);
        left = tryFold(Type.And, left, right);
        skipWhitespace(text);
    }
    return left;
}

Expression* parseEqualityExp(ref const(char)[] text)
{
    Expression* left = parseRelationalExp(text);
    scope(failure) freeExpression(left);
    skipWhitespace(text);
    while (text.match("==") || text.match("!="))
    {
        version (ExpressionDebug)
            writeDebug("EQ");
        Type ty = text.ptr[-1] == '=' ? Type.Eq : Type.Ne;
        skipWhitespace(text);
        Expression* right = parseRelationalExp(text);
        left = tryFold(ty, left, right);
        skipWhitespace(text);
    }
    return left;
}

Expression* parseRelationalExp(ref const(char)[] text)
{
    Expression* left = parseConcatExp(text);
    scope(failure) freeExpression(left);
    skipWhitespace(text);
    while (text.match('<') || text.match("<=") || text.match('>') || text.match(">="))
    {
        version (ExpressionDebug)
            writeDebug("REL");
        Type ty = text.ptr[-1] == '=' ? Type.Le : Type.Lt;
        bool swap = text.ptr[text.ptr[-1] == '=' ? -2 : -1] == '>';
        skipWhitespace(text);
        Expression* right = parseConcatExp(text);
        left = tryFold(ty, swap ? right : left, swap ? left : right);
        skipWhitespace(text);
    }
    return left;
}

Expression* parseConcatExp(ref const(char)[] text)
{
    Expression* left = parseAdditiveExp(text);
    scope(failure) freeExpression(left);
    skipWhitespace(text);
    while (text.match(".."))
    {
        version (ExpressionDebug)
            writeDebug("CAT");
        skipWhitespace(text);
        Expression* right = parseAdditiveExp(text);
        left = tryFold(Type.Cat, left, right);
        skipWhitespace(text);
    }
    return left;
}

Expression* parseAdditiveExp(ref const(char)[] text)
{
    Expression* left = parseMultiplicativeExp(text);
    scope(failure) freeExpression(left);
    skipWhitespace(text);
    while (text.match('+') || text.match('-'))
    {
        version (ExpressionDebug)
            writeDebug("ADD");
        Type ty = text.ptr[-1] == '+' ? Type.Add : Type.Sub;
        skipWhitespace(text);
        Expression* right = parseMultiplicativeExp(text);
        left = tryFold(ty, left, right);
        skipWhitespace(text);
    }
    return left;
}

Expression* parseMultiplicativeExp(ref const(char)[] text)
{
    Expression* left = parseUnaryExp(text);
    scope(failure) freeExpression(left);
    skipWhitespace(text);
    while (text.match('*') || text.match('/') || text.match('%'))
    {
        version (ExpressionDebug)
            writeDebug("MUL");
        Type ty = text.ptr[-1] == '*' ? Type.Mul : text.ptr[-1] == '/' ? Type.Div : Type.Mod;
        skipWhitespace(text);
        Expression* right = parseUnaryExp(text);
        left = tryFold(ty, left, right);
        skipWhitespace(text);
    }
    return left;
}

Expression* parseUnaryExp(ref const(char)[] text)
{
    if (text.match('-') || text.match('!') || text.match('+'))
    {
        version (ExpressionDebug)
            writeDebug("UNARY");
        char op = text.ptr[-1];
        Expression* expr = parseUnaryExp(text);
        if (op == '+')
            return expr;
        Type ty = op ? Type.Neg : Type.Not;
        return tryFold(ty, expr, null);
    }
    return parsePostfixExp(text);
}

Expression* parsePostfixExp(ref const(char)[] text)
{
    Expression* left = parsePrimaryExp(text);
    scope(failure) freeExpression(left);
    while (text.match('['))
    {
        version (ExpressionDebug)
            writeDebug("IDX [");
        skipWhitespace(text);
        Expression* expr = parseExpression(text);
        scope(failure) freeExpression(expr);
        skipWhitespace(text);
        text.expect(']');
        version (ExpressionDebug)
            writeDebug("IDX ]");
        left = tryFold(Type.Idx, left, expr);
    }
    return left;
}

Expression* parsePrimaryExp(ref const(char)[] text)
{
    if (text.length == 0)
        syntaxError("Expected expression");

    // parse paren-enclosed expression
    if (text.match('('))
    {
        version (ExpressionDebug)
            writeDebug("PAREN (");
        skipWhitespace(text);
        Expression* expr = parseExpression(text);
        scope(failure) freeExpression(expr);
        skipWhitespace(text);
        text.expect(')');
        version (ExpressionDebug)
            writeDebug("PAREN )");
        return expr;
    }

    // parse command blocks
    if (text.match('[') || text.match('{'))
    {
        bool eval = text.ptr[-1] == '[';
        Array!ScriptCommand commands = parseCommands(text);
        if (eval)
            text.expect(']');
        else
            text.expect('}');
        Expression* cmds = allocExpression(Type.CmdList);
        commands.moveEmplace(cmds.cmds);
        if (eval)
            cmds.flags |= Flags.CommandEval;
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
            r = allocExpression(copy.move);
        else
        {
            r = allocExpression(Type.Str);
            r.s = text[0 .. len];
        }
        r.flags = Flags.Constant;
        if (interpolated)
            r.flags |= Flags.InterpolatedString;

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

        identifier = text[0].isAlpha || text[0] == '_' || text[0] == '/';
        if (!identifier)
            numeric = text[0].isNumeric || (!isVar && (text[0] == '-' || text[0] == '+') && text.length > 1 && text[1].isNumeric);

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

            if (identifier && !c.isAlphaNumeric && c != '_' && c != '-')
            {
                if (isVar)
                    break;
                identifier = false;
            }
            else if (numeric && !c.isNumeric)
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
            if (!text[len].isWhitespace && text[len] != '=' && text[len] != '/' && text[len] != ';' && text[len] != ',' && text[len] != ')' && text[len] != '}' && text[len] != ']')
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
            r = allocExpression(Type.Num);
            r.flags = Flags.Constant;
            r.f = f;

            version (ExpressionDebug)
                writeDebug("NUM: ", r.f);
        }
        else
        {
            if (isVar && !identifier && !numeric)
                syntaxError("Expected identifier");
            r = allocExpression(isVar ? Type.Var : Type.Str);
            r.flags = Flags.NoQuotes;
            if (identifier)
                r.flags |= Flags.Identifier;
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
        r = allocExpression(Type.Arr);
        arr.moveEmplace(r.arr);
    }

    return r;
}


Expression* tryFold(Type ty, Expression* l, Expression* r)
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
        exp = allocExpression(ty);
        exp.left = l;
        exp.right = r;
    }
    return exp;
}

Expression* fold(Type ty, Expression* l, Expression* r)
{
    // attempt constant folding...

    // can only fold if both sides are constant...
    if (l.ty >= Type.Var || (ty >= Type.Idx && r.ty >= Type.Var))
        return null;

    // result will overwrite and return `l`
    // caller is responsible for destroying `r` if not null

    switch (ty)
    {
        case Type.Not:
            bool lb = l.asBool;
            *l = Expression(Type.Num);
            l.f = !lb;
            return l;

        case Type.Neg:
            double lf = l.asNum;
            *l = Expression(Type.Num);
            l.f = -lf;
            return l;

        case Type.Cat:
            MutableString!0 s;
            if (l.ty == Type.Str)
                s = l.getStr;
            else
                s ~= l.asNum;
            if (r.ty == Type.Str)
                s ~= r.getStr;
            else
                s ~= r.asNum;
            *l = Expression(s.move);
            return l;

        case Type.Or:
        case Type.And:
            bool ltrue = l.asBool;
            bool rtrue = r.asBool;
            *l = Expression(Type.Num);
            l.f = ty == Type.Or ? ltrue || rtrue : ltrue && rtrue;
            return l;

        case Type.Eq:
        case Type.Ne:
        case Type.Lt:
        case Type.Le:
            if (l.ty == Type.Str && r.ty == Type.Str)
            {
                // string comparison
                ptrdiff_t t = l.getStr().cmp(r.getStr());
                *l = Expression(Type.Num);
                l.f = ty == Type.Eq ? t == 0 :
                      ty == Type.Ne ? t != 0 :
                      ty == Type.Lt ? t < 0 :
                                      t <= 0;
                return l;
            }
            goto case;

        case Type.Add:
        case Type.Sub:
        case Type.Mul:
        case Type.Div:
        case Type.Mod:
            double lf = l.asNum;
            double rf = r.asNum;
            *l = Expression(Type.Num);
            switch (ty)
            {
                case Type.Eq: l.f = lf == rf; break;
                case Type.Ne: l.f = lf != rf; break;
                case Type.Lt: l.f = lf < rf; break;
                case Type.Le: l.f = lf <= rf; break;
                case Type.Add: l.f = lf + rf; break;
                case Type.Sub: l.f = lf - rf; break;
                case Type.Mul: l.f = lf * rf; break;
                case Type.Div: l.f = lf / rf; break;
                case Type.Mod: l.f = lf % rf; break;
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
