module urt.format.json;

import urt.array;
import urt.conv;
import urt.lifetime;
import urt.kvp;
import urt.mem.allocator;
import urt.string;
import urt.string.format;

public import urt.variant;

nothrow @nogc:


Variant parseJson(const(char)[] text)
{
    return parseNode(text);
}

ptrdiff_t writeJson(ref const Variant val, char[] buffer, bool dense = false, uint level = 0, uint indent = 2)
{
    final switch (val.type)
    {
        case Variant.Type.Null:
            if (!buffer.ptr)
                return 4;
            if (buffer.length < 4)
                return -1;
            buffer[0 .. 4] = "null";
            return 4;

        case Variant.Type.False:
            if (!buffer.ptr)
                return 5;
            if (buffer.length < 5)
                return -1;
            buffer[0 .. 5] = "false";
            return 5;

        case Variant.Type.True:
            if (!buffer.ptr)
                return 4;
            if (buffer.length < 4)
                return -1;
            buffer[0 .. 4] = "true";
            return 4;

        case Variant.Type.Map:
        case Variant.Type.Array:
            if (!buffer.ptr)
            {
                ptrdiff_t len;
                size_t itemCount = val.type == Variant.Type.Map ? val.count /2 : val.count;
                if (dense)
                {
                    // open/close brackets + comma-space separators
                    len = 2 + (itemCount - 1)*2;
                    if (val.type == Variant.Type.Map)
                    {
                        // colon separators
                        len += itemCount;
                    }
                }
                else
                {
                    // open/close brackets + comma separators + element newlines + final newline
                    len = 2 + (itemCount - 1) + itemCount*(1 + level + indent) + (1 + level);
                    if (val.type == Variant.Type.Map)
                    {
                        // colon-space separators
                        len += itemCount*2;
                    }
                }
                // ...and the elements
                int inc = val.type == Variant.Type.Map ? 2 : 1;
                for (uint i = 0; i < val.count; i += inc)
                {
                    len += writeJson(val.value.n[i], null, dense, level + indent, indent);
                    if (val.type == Variant.Type.Map)
                        len += writeJson(val.value.n[i + 1], null, dense, level + indent, indent);
                }
                return len;
            }

            ptrdiff_t written = 0;
            if (!buffer.append(written, val.type == Variant.Type.Map ? '{' : '['))
                return -1;
            int inc = val.type == Variant.Type.Map ? 2 : 1;
            for (uint i = 0; i < val.count; i += inc)
            {
                if (i > 0)
                {
                    if (!buffer.append(written, ',') || (dense && !buffer.append(written, ' ')))
                        return -1;
                }
                if (!dense)
                {
                    if (!buffer.newline(written, level + indent))
                        return -1;
                }
                ptrdiff_t len = writeJson(val.value.n[i], buffer[written .. $], dense, level + indent, indent);
                if (len < 0)
                    return -1;
                written += len;
                if (val.type == Variant.Type.Map)
                {
                    if (!buffer.append(written, ':') || (!dense && !buffer.append(written, ' ')))
                        return -1;
                    len = writeJson(val.value.n[i + 1], buffer[written .. $], dense, level + indent, indent);
                    if (len < 0)
                        return -1;
                    written += len;
                }
            }
            if (!dense && !buffer.newline(written, level))
                return -1;
            if (!buffer.append(written, val.type == Variant.Type.Map ? '}' : ']'))
                return -1;
            return written;

        case Variant.Type.String:
            const char[] s = val.asString();
            if (buffer.ptr)
            {
                if (buffer.length < s.length + 2)
                    return -1;
                buffer[0] = '"';
                buffer[1 .. 1 + s.length] = s[];
                buffer[1 + s.length] = '"';
            }
            return s.length + 2;

        case Variant.Type.Number:
            import urt.conv;

            if (val.isQuantity())
                assert(false, "TODO: implement quantity formatting for JSON");

            if (val.isDouble())
                return val.asDouble().formatFloat(buffer);

            // TODO: parse args?
            //format

            if (val.isUlong())
                return val.asUlong().formatUint(buffer);
            return val.asLong().formatInt(buffer);

        case Variant.Type.User:
            // in order to text-ify a user type, we probably need a hash table of text-ify functions, which
            // we can lookup by the typeId...
            // the tricky bit is, we need to init the table based on instantiations of constructors for each T...
            // maybe an object with static constructor for each instantiation, which will hook it into the table?
            assert(false, "TODO...");
    }
}


unittest
{
    enum doc = `{
        "nothing": null,
        "name": "John Doe",
        "age": 42,
        "neg": -42,
        "sobig": 8234567890,
        "married": true,
        "worried": false,
        "children": [
            {
                "name": "Jane Doe",
                "age": 12
            },
            {
                "name": "Jack Doe",
                "age": 8
            }
        ]
    }`;

    Variant root = parseJson(doc);

    // check the data was parsed correctly...
    assert(root["nothing"].isNull);
    assert(root["name"].asString == "John Doe");
    assert(root["age"].asUint == 42);
    assert(root["neg"].asInt == -42);
    assert(root["sobig"].asLong == 8234567890);
    assert(root["married"].isTrue);
    assert(root["worried"].asBool == false);
    assert(root["children"].length == 2);
    assert(root["children"][0]["name"].asString == "Jane Doe");
    assert(root["children"][0]["age"].asInt == 12);
    assert(root["children"][1]["name"].asString == "Jack Doe");
    assert(root["children"][1]["age"].asInt == 8);

    char[1024] buffer = void;
    // check the dense writer...
    assert(root["children"].writeJson(null, true) == 61);
    assert(root["children"].writeJson(buffer, true) == 61);
    assert(buffer[0 .. 61] == `[{"name":"Jane Doe", "age":12}, {"name":"Jack Doe", "age":8}]`);

    // check the expanded writer
    assert(root["children"].writeJson(null, false, 0, 1) == 83);
    assert(root["children"].writeJson(buffer, false, 0, 1) == 83);
    assert(buffer[0 .. 83] == "[\n {\n  \"name\": \"Jane Doe\",\n  \"age\": 12\n },\n {\n  \"name\": \"Jack Doe\",\n  \"age\": 8\n }\n]");

    // check indentation works properly
    assert(root["children"].writeJson(null, false, 0, 2) == 95);
    assert(root["children"].writeJson(buffer, false, 0, 2) == 95);
    assert(buffer[0 .. 95] == "[\n  {\n    \"name\": \"Jane Doe\",\n    \"age\": 12\n  },\n  {\n    \"name\": \"Jack Doe\",\n    \"age\": 8\n  }\n]");

    // fabricate a JSON object
    Variant write;
    write.asArray ~= Variant(42);
    write.asArray ~= Variant(VariantKVP("wow", Variant(true)), VariantKVP("bogus", Variant(false)));

    assert(write.length == 2);
    assert(write[0].asInt == 42);
    assert(write[1]["wow"].isTrue);
    assert(write[1]["bogus"].asBool == false);
    assert(write.writeJson(buffer, true) == 33);
    assert(buffer[0 .. 33] == "[42, {\"wow\":true, \"bogus\":false}]");
}


private:

bool append(char[] buffer, ref ptrdiff_t offset, char c)
{
    if (offset >= buffer.length)
        return false;
    buffer[offset++] = c;
    return true;
}
ptrdiff_t newline(char[] buffer, ref ptrdiff_t offset, int level)
{
    if (offset + level >= buffer.length)
        return false;
    buffer[offset++] = '\n';
    buffer[offset .. offset + level] = ' ';
    offset += level;
    return true;
}

Variant parseNode(ref const(char)[] text)
{
    text = text.trimFront();

    if (text.empty)
        return Variant();
    else if (text.startsWith("null"))
    {
        text = text[4 .. $];
        return Variant();
    }
    else if (text.startsWith("true"))
    {
        text = text[4 .. $];
        return Variant(true);
    }
    else if (text.startsWith("false"))
    {
        text = text[5 .. $];
        return Variant(false);
    }
    else if (text[0] == '"')
    {
        assert(text.length > 1);
        size_t i = 1;
        while (i < text.length && text[i] != '"')
        {
            // TODO: we need to collapse the escape sequence, so we need to copy the string somewhere >_<
            //       ...overwrite the source buffer?
            if (text[i] == '\\')
            {
                assert(i + 1 < text.length);
                i += 2;
            }
            else
                i++;
        }
        assert(i < text.length);
        Variant node = Variant(text[1 .. i]);
        text = text[i + 1 .. $];
        return node;
    }
    else if (text[0] == '{' || text[0] == '[')
    {
        Array!Variant tmp;

        bool isArray = text[0] == '[';
        text = text[1 .. $];

        bool expectComma = false;
        while (true)
        {
            text = text.trimFront;
            if (text.length == 0 || text[0] == (isArray ? ']' : '}'))
                break;
            else if (expectComma)
            {
                if (text[0] == ',')
                    text = text[1 .. $].trimFront;
            }
            else
                expectComma = true;

            tmp ~= parseNode(text);
            if (!isArray)
            {
                assert(tmp.back().isString());

                text = text.trimFront;
                assert(text.length > 0 && text[0] == ':');
                text = text[1 .. $].trimFront;
                tmp ~= parseNode(text);
            }
        }
        assert(text.length > 0);
        text = text[1 .. $];

        Variant r = Variant(tmp.move);
        if (!isArray)
            r.flags = Variant.Flags.Map;
        return r;
    }
    else if (text[0].isNumeric || (text[0] == '-' && text.length > 1 && text[1].isNumeric))
    {
        bool neg = text[0] == '-';
        size_t taken = void;
        ulong div = void;
        ulong value = text[neg .. $].parseUintWithDecimal(div, &taken, 10);
        assert(taken > 0);
        text = text[taken + neg .. $];

        if (div > 1)
        {
            double d = cast(double)value;
            if (neg)
                d = -d;
            d /= div;
            return Variant(d);
        }
        else
        {
            if (neg)
            {
                assert(value <= long.max + 1);
                return Variant(-cast(long)value);
            }
            else
                return Variant(value);
        }
    }
    else
        assert(false, "Invalid JSON!");
}
