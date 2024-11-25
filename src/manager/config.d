module manager.config;

import urt.array;
import urt.string;

nothrow @nogc:


enum DirectiveDelimiter = '$';
enum CommentDelimiter = '#';


struct ConfItem
{
    this(this) @disable;

    const(char)[] name;
    const(char)[] value;
    Array!ConfItem subItems;

    this(ref typeof(this) other) nothrow @nogc
    {
        this.name = other.name;
        this.value = other.value;
        this.subItems = other.subItems[];
    }
}

ConfItem parseConfig(const(char)[] text)
{
    struct ParseStack
    {
        ulong indent;
        ConfItem* item;
    }

    ConfItem root;
    int depth = 0;
    ParseStack[128] stack;
    stack[0].item = &root;

    while (!text.empty)
    {
        const(char)[] line = text.takeLine;
        ulong indent;
        line = line.stripIndentation(indent);
        line = line.trimComment!CommentDelimiter;
        if (line.empty)
            continue;

        const(char)[] key, value = line;
        if (line[0] == DirectiveDelimiter)
            key = value.split!' ';
        else
            key = value.split!':';

        if (indent > stack[depth].indent)
        {
            if (depth == 0 && stack[0].item.subItems.length == 0)
                stack[0].indent = indent;
            else
            {
                stack[depth + 1].item = &stack[depth].item.subItems[$-1];
                stack[++depth].indent = indent;
            }
        }
        else if (indent < stack[depth].indent)
        {
            while (depth > 0)
            {
                --depth;
                if (indent == stack[depth].indent)
                    break;
                if (indent > stack[depth].indent)
                    assert(0); // ?!! indent level didn't exist in outer scope
            }
        }

        if (!key.empty && key[0] == DirectiveDelimiter)
        {
            if (key[] == DirectiveDelimiter ~ "import")
            {
                assert(false);
//                ConfItem subConfig = parseConfigFile(value);
//                stack[depth].item.subItems ~= subConfig.subItems[];
            }
        }
        else
            stack[depth].item.subItems ~= ConfItem(key, value);
    }

    return root;
}


private:

const(char)[] stripIndentation(const(char)[] s, out ulong indentPattern)
{
    ulong pattern = 0;
    size_t i = 0;
    for (; i < s.length; ++i)
    {
        if (s[i] == ' ')
            pattern = (pattern << 2) | 1;
        else if (s[i] == '\t')
            pattern = (pattern << 2) | 2;
        else
            break;
    }
    indentPattern = pattern;
    return s[i .. $];
}
