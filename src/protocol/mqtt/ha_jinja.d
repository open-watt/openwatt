module protocol.mqtt.ha_jinja;

import urt.mem.allocator;
import urt.string;

import manager.expression : Expression, free_expression, parse_expression;

nothrow @nogc:


bool compile_jinja_template(const(char)[] template_, out String source, out Expression* expression)
{
    if (template_.empty)
        return true;

    const(char)[] body = template_.trim();
    if (!body.startsWith("{{") || body.length < 4 || body[$ - 2 .. $] != "}}")
        return false;
    body = body[2 .. $ - 2].trim();
    if (body.empty)
        return false;

    MutableString!0 lowered;
    if (!lower_jinja_expression(body, lowered))
        return false;
    source = lowered[].makeString(defaultAllocator());

    const(char)[] cursor = source[];
    try
        expression = parse_expression(cursor);
    catch (Exception)
    {
        if (expression)
            expression.free_expression();
        expression = null;
        return false;
    }
    if (!cursor.trim().empty)
    {
        expression.free_expression();
        expression = null;
        return false;
    }
    return true;
}

unittest
{
    MutableString!0 lowered;
    assert(lower_jinja_expression("value | int / 10 if value | is_number else none", lowered));
    assert(lowered[] == "$select($is_number($value), $to_int($value) / 10, null)");

    lowered.clear();
    assert(lower_jinja_expression("value | float(0) | round(1)", lowered));
    assert(lowered[] == "$round($to_float($value, 0), 1)");

    lowered.clear();
    assert(lower_jinja_expression("value | trim | lower | default('unknown', true)", lowered));
    assert(lowered[] == "$select($truthy($lower($trim($value))), $lower($trim($value)), \"unknown\")");

    lowered.clear();
    assert(lower_jinja_expression("value | bool(default=false) | iif('ON', 'OFF')", lowered));
    assert(lowered[] == "$select($to_bool($value, false), \"ON\", \"OFF\")");

    String source;
    Expression* expression;
    assert(compile_jinja_template("{{ value | int * 10 }}", source, expression));
    scope(exit) expression.free_expression();
    assert(source[] == "$to_int($value) * 10");
}

private:

bool lower_jinja_expression(const(char)[] input, ref MutableString!0 output)
{
    input = input.trim();
    size_t conditional = find_top_level_word(input, "if");
    if (conditional == input.length)
        return lower_jinja_pipeline(input, output);

    size_t otherwise = find_top_level_word(input, "else", conditional + 2);
    if (otherwise == input.length)
        return false;

    const(char)[] accepted = input[0 .. conditional].trim();
    const(char)[] condition = input[conditional + 2 .. otherwise].trim();
    const(char)[] rejected = input[otherwise + 4 .. $].trim();
    if (accepted.empty || condition.empty || rejected.empty)
        return false;

    output ~= "$select(";
    if (!lower_jinja_expression(condition, output))
        return false;
    output ~= ", ";
    if (!lower_jinja_expression(accepted, output))
        return false;
    output ~= ", ";
    if (!lower_jinja_expression(rejected, output))
        return false;
    output ~= ')';
    return true;
}

bool lower_jinja_pipeline(const(char)[] input, ref MutableString!0 output)
{
    size_t pipe = find_last_top_level_char(input, '|');
    if (pipe == input.length)
        return lower_jinja_tokens(input, output);

    const(char)[] base = input[0 .. pipe].trim();
    const(char)[] filter = input[pipe + 1 .. $].trim();
    if (base.empty || filter.empty)
        return false;

    size_t name_end = 0;
    while (name_end < filter.length &&
           (filter[name_end].is_alpha_numeric || filter[name_end] == '_'))
        ++name_end;
    const(char)[] name = filter[0 .. name_end];
    const(char)[] intrinsic = filter_intrinsic(name);
    if (intrinsic.empty)
        return false;

    const(char)[] args;
    const(char)[] tail = filter[name_end .. $];
    const(char)[] trimmed_tail = tail.trimFront();
    if (!trimmed_tail.empty && trimmed_tail[0] == '(')
    {
        size_t close = find_matching_paren(trimmed_tail);
        if (close == trimmed_tail.length)
            return false;
        args = trimmed_tail[1 .. close];
        tail = trimmed_tail[close + 1 .. $];
    }

    const(char)[] fallback;
    bool falsey_default;
    if (name == "default" || name == "d")
    {
        size_t comma = find_top_level_char(args, ',');
        fallback = strip_named_argument(args[0 .. comma].trim());
        if (fallback.empty)
            return false;
        if (comma != args.length)
        {
            const(char)[] boolean = args[comma + 1 .. $].trim();
            if (find_top_level_char(boolean, ',') != boolean.length)
                return false;
            boolean = strip_named_argument(boolean);
            if (boolean == "true")
                falsey_default = true;
            else if (boolean != "false")
                return false;
        }
        args = null;
    }

    MutableString!0 applied;
    applied ~= '$';
    applied ~= intrinsic;
    applied ~= '(';
    if (!lower_jinja_pipeline(base, applied))
        return false;
    while (!args.trim().empty)
    {
        size_t comma = find_top_level_char(args, ',');
        const(char)[] arg = strip_named_argument(args[0 .. comma].trim());
        if (arg.empty)
            return false;
        applied ~= ", ";
        if (!lower_jinja_expression(arg, applied))
            return false;
        if (comma == args.length)
            args = null;
        else
            args = args[comma + 1 .. $];
    }
    applied ~= ')';

    if (name == "default" || name == "d")
    {
        MutableString!0 lowered_base;
        if (!lower_jinja_pipeline(base, lowered_base))
            return false;
        if (falsey_default)
            output ~= "$select($truthy(";
        else
            output ~= "$select($is_null(";
        output ~= lowered_base[];
        output ~= "), ";
        if (falsey_default)
        {
            output ~= lowered_base[];
            output ~= ", ";
            if (!lower_jinja_expression(fallback, output))
                return false;
        }
        else
        {
            if (!lower_jinja_expression(fallback, output))
                return false;
            output ~= ", ";
            output ~= lowered_base[];
        }
        output ~= ')';
    }
    else
        output ~= applied[];
    if (!lower_jinja_tokens(tail, output))
        return false;
    return true;
}

const(char)[] filter_intrinsic(const(char)[] name) pure
{
    switch (name)
    {
        case "int":       return "to_int";
        case "float":     return "to_float";
        case "bool":      return "to_bool";
        case "string":    return "to_string";
        case "is_number": return "is_number";
        case "abs":       return "abs";
        case "round":     return "round";
        case "min":       return "min";
        case "max":       return "max";
        case "default":
        case "d":         return "default";
        case "iif":       return "select";
        case "lower":     return "lower";
        case "upper":     return "upper";
        case "trim":      return "trim";
        case "length":
        case "count":     return "length";
        default:           return null;
    }
}

const(char)[] strip_named_argument(const(char)[] arg) pure
{
    size_t equal = find_top_level_char(arg, '=');
    if (equal == arg.length ||
        (equal + 1 < arg.length && arg[equal + 1] == '=') ||
        (equal > 0 && (arg[equal - 1] == '=' || arg[equal - 1] == '!' ||
                      arg[equal - 1] == '<' || arg[equal - 1] == '>')))
        return arg;
    const(char)[] name = arg[0 .. equal].trim();
    if (name.empty || !(name[0].is_alpha || name[0] == '_'))
        return null;
    foreach (c; name[1 .. $])
        if (!(c.is_alpha_numeric || c == '_'))
            return null;
    return arg[equal + 1 .. $].trim();
}

bool lower_jinja_tokens(const(char)[] input, ref MutableString!0 output)
{
    for (size_t i = 0; i < input.length; )
    {
        char c = input[i];
        if (c == '|' || c == '{' || c == '}')
            return false;
        if (c == '\'' || c == '"')
        {
            char quote = c;
            output ~= '"';
            ++i;
            while (i < input.length)
            {
                c = input[i++];
                if (c == quote)
                {
                    output ~= '"';
                    break;
                }
                if (c == '\\' && i < input.length)
                {
                    char escaped = input[i++];
                    if (escaped == '"')
                        output ~= '\\';
                    output ~= escaped;
                }
                else
                {
                    if (c == '"')
                        output ~= '\\';
                    output ~= c;
                }
            }
            if (c != quote)
                return false;
            continue;
        }
        if (c.is_alpha || c == '_')
        {
            size_t end = i + 1;
            while (end < input.length &&
                   (input[end].is_alpha_numeric || input[end] == '_'))
                ++end;
            const(char)[] token = input[i .. end];
            if (token == "value" || token == "value_json")
                output ~= '$';
            if (token == "none")
                output ~= "null";
            else
                output ~= token;
            i = end;
            continue;
        }
        output ~= c;
        ++i;
    }
    return true;
}

size_t find_top_level_word(const(char)[] input, const(char)[] word, size_t start = 0) pure
{
    int depth;
    char quote = 0;
    for (size_t i = start; i + word.length <= input.length; ++i)
    {
        char c = input[i];
        if (quote)
        {
            if (c == '\\')
                ++i;
            else if (c == quote)
                quote = 0;
            continue;
        }
        if (c == '\'' || c == '"')
        {
            quote = c;
            continue;
        }
        if (c == '(' || c == '[')
        {
            ++depth;
            continue;
        }
        if (c == ')' || c == ']')
        {
            --depth;
            continue;
        }
        if (depth || input[i .. i + word.length] != word)
            continue;
        bool left = i == 0 || !(input[i - 1].is_alpha_numeric || input[i - 1] == '_');
        size_t end = i + word.length;
        bool right = end == input.length || !(input[end].is_alpha_numeric || input[end] == '_');
        if (left && right)
            return i;
    }
    return input.length;
}

size_t find_top_level_char(const(char)[] input, char needle) pure
{
    int depth;
    char quote = 0;
    for (size_t i = 0; i < input.length; ++i)
    {
        char c = input[i];
        if (quote)
        {
            if (c == '\\')
                ++i;
            else if (c == quote)
                quote = 0;
            continue;
        }
        if (c == '\'' || c == '"')
        {
            quote = c;
            continue;
        }
        if (c == '(' || c == '[')
            ++depth;
        else if (c == ')' || c == ']')
            --depth;
        else if (!depth && c == needle)
            return i;
    }
    return input.length;
}

size_t find_last_top_level_char(const(char)[] input, char needle) pure
{
    size_t result = input.length;
    size_t offset;
    while (offset < input.length)
    {
        size_t found = find_top_level_char(input[offset .. $], needle);
        if (found == input.length - offset)
            break;
        result = offset + found;
        offset = result + 1;
    }
    return result;
}

size_t find_matching_paren(const(char)[] input) pure
{
    assert(!input.empty && input[0] == '(');
    int depth;
    char quote = 0;
    for (size_t i = 0; i < input.length; ++i)
    {
        char c = input[i];
        if (quote)
        {
            if (c == '\\')
                ++i;
            else if (c == quote)
                quote = 0;
            continue;
        }
        if (c == '\'' || c == '"')
        {
            quote = c;
            continue;
        }
        if (c == '(')
            ++depth;
        else if (c == ')' && --depth == 0)
            return i;
    }
    return input.length;
}
