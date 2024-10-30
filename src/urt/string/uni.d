module urt.string.uni;

nothrow @nogc:


size_t uniConvert(const(char)[] s, wchar[] buffer)
{
    const(char)* p = s.ptr;
    const(char)* pend = p + s.length;
    wchar* b = buffer.ptr;
    wchar* bEnd = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bEnd)
            return 0; // End of output buffer
        if ((*p & 0x80) == 0) // 1-byte sequence: 0xxxxxxx
            *b++ = *p++;
        else if ((*p & 0xE0) == 0xC0) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (p + 1 >= pend)
                return 0; // Unexpected end of input
            *b++ = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F);
            p += 2;
        }
        else if ((*p & 0xF0) == 0xE0) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
            if (p + 2 >= pend)
                return 0; // Unexpected end of input
            *b++ = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
            p += 3;
        }
        else if ((*p & 0xF8) == 0xF0) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        {
            if (p + 3 >= pend || b + 1 >= bEnd)
                return 0; // Unexpected end of input/output
            dchar codepoint = ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F);
            codepoint -= 0x10000;
            b[0] = 0xD800 | (codepoint >> 10);
            b[1] = 0xDC00 | (codepoint & 0x3FF);
            p += 4;
            b += 2;
        }
        else
            return 0; // Invalid UTF-8 sequence
    }
    return b - buffer.ptr;
}

size_t uniConvert(const(char)[] s, dchar[] buffer)
{
    const(char)* p = s.ptr;
    const(char)* pend = p + s.length;
    dchar* b = buffer.ptr;
    dchar* bEnd = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bEnd)
            return 0;
        if ((*p & 0x80) == 0) // 1-byte sequence: 0xxxxxxx
            *b++ = *p++;
        else if ((*p & 0xE0) == 0xC0) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (p + 1 >= pend)
                return 0; // Unexpected end of input.
            *b++ = ((*p++ & 0x1F) << 6) | (*p++ & 0x3F);
        }
        else if ((*p & 0xF0) == 0xE0) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
            if (p + 2 >= pend)
                return 0; // Unexpected end of input.
            *b++ = ((*p++ & 0x0F) << 12) | ((*p++ & 0x3F) << 6) | (*p++ & 0x3F);
        }
        else if ((*p & 0xF8) == 0xF0) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        {
            if (p + 3 >= pend)
                return 0; // Unexpected end of input.
            *b++ = ((*p++ & 0x07) << 18) | ((*p++ & 0x3F) << 12) | ((*p++ & 0x3F) << 6) | (*p++ & 0x3F);
        }
        else
            return 0; // Invalid UTF-8 sequence.
    }
    return b - buffer.ptr;
}

size_t uniConvert(const(wchar)[] s, char[] buffer)
{
    const(wchar)* p = s.ptr;
    const(wchar)* pend = p + s.length;
    char* b = buffer.ptr;
    char* bEnd = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bEnd)
            return 0; // End of output buffer
        if (p[0] >= 0xD800)
        {
            if (p[0] >= 0xE000)
                goto three_byte_seq;
            if (p + 1 >= pend)
                return 0; // Unexpected end of input
            if (p[0] < 0xDC00) // Surrogate pair: 110110xxxxxxxxxx 110111xxxxxxxxxx
            {
                if (b + 3 >= bEnd)
                    return 0; // End of output buffer
                dchar codepoint = 0x10000 + ((p[0] - 0xD800) << 10) + (p[1] - 0xDC00);
                b[0] = 0xF0 | (codepoint >> 18);
                b[1] = 0x80 | ((codepoint >> 12) & 0x3F);
                b[2] = 0x80 | ((codepoint >> 6) & 0x3F);
                b[3] = 0x80 | (codepoint & 0x3F);
                p += 2;
                b += 4;
                continue;
            }
            return 0; // Invalid UTF-16 sequence
        }
        if (*p < 0x80) // 1-byte sequence: 0xxxxxxx
            *b++ = cast(char)*p++;
        else if (*p < 0x800) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (b + 1 >= bEnd)
                return 0; // End of output buffer
            b[0] = 0xC0 | cast(char)(*p >> 6);
            b[1] = 0x80 | (*p++ & 0x3F);
            b += 2;
        }
        else // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
        three_byte_seq:
            if (b + 2 >= bEnd)
                return 0; // End of output buffer
            b[0] = 0xE0 | (*p >> 12);
            b[1] = 0x80 | ((*p >> 6) & 0x3F);
            b[2] = 0x80 | (*p++ & 0x3F);
            b += 3;
        }
    }
    return b - buffer.ptr;
}

size_t uniConvert(const(wchar)[] s, dchar[] buffer)
{
    const(wchar)* p = s.ptr;
    const(wchar)* pend = p + s.length;
    dchar* b = buffer.ptr;
    dchar* bEnd = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bEnd)
            return 0; // End of output buffer
        if (p[0] >= 0xD800 && p[0] < 0xE000)
        {
            if (p + 1 >= pend)
                return 0; // Unexpected end of input
            if (p[0] < 0xDC00) // Surrogate pair: 110110xxxxxxxxxx 110111xxxxxxxxxx
            {
                *b++ = 0x10000 + ((p[0] - 0xD800) << 10) + (p[1] - 0xDC00);
                p += 2;
                continue;
            }
            return 0; // Invalid UTF-16 sequence
        }
        *b++ = *p++;
    }
    return b - buffer.ptr;
}

size_t uniConvert(const(dchar)[] s, char[] buffer)
{
    const(dchar)* p = s.ptr;
    const(dchar)* pend = p + s.length;
    char* b = buffer.ptr;
    char* bEnd = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bEnd)
            return 0; // End of output buffer
        if (*p < 0x80) // 1-byte sequence: 0xxxxxxx
            *b++ = cast(char)*p++;
        else if (*p < 0x800) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (b + 1 >= bEnd)
                return 0; // End of output buffer
            b[0] = 0xC0 | cast(char)(*p >> 6);
            b[1] = 0x80 | (*p++ & 0x3F);
            b += 2;
        }
        else if (*p < 0x10000) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
            if (b + 2 >= bEnd)
                return 0; // End of output buffer
            b[0] = 0xE0 | cast(char)(*p >> 12);
            b[1] = 0x80 | ((*p >> 6) & 0x3F);
            b[2] = 0x80 | (*p++ & 0x3F);
            b += 3;
        }
        else if (*p < 0x110000) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        {
            if (b + 3 >= bEnd)
                return 0; // End of output buffer
            b[0] = 0xF0 | (*p >> 18);
            b[1] = 0x80 | ((*p >> 12) & 0x3F);
            b[2] = 0x80 | ((*p >> 6) & 0x3F);
            b[3] = 0x80 | (*p++ & 0x3F);
            b += 4;
        }
        else
            return 0; // Invalid UTF codepoint
    }
    return b - buffer.ptr;
}

size_t uniConvert(const(dchar)[] s, wchar[] buffer)
{
    const(dchar)* p = s.ptr;
    const(dchar)* pend = p + s.length;
    wchar* b = buffer.ptr;
    wchar* bEnd = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bEnd)
            return 0; // End of output buffer
        if (*p < 0x10000)
            *b++ = cast(wchar)*p++;
        else if (*p < 0x110000)
        {
            if (b + 1 >= bEnd)
                return 0; // End of output buffer
            dchar codepoint = *p++ - 0x10000;
            b[0] = 0xD800 | (codepoint >> 10);
            b[1] = 0xDC00 | (codepoint & 0x3FF);
            b += 2;
        }
        else
            return 0; // Invalid codepoint
    }
    return b - buffer.ptr;
}

unittest
{
    immutable dstring unicodeTest = 
        "Basic ASCII: Hello, World!\n" ~
        "BMP Examples: 你好, مرحبا, שלום, 😊, ☂️\n" ~
        "Supplementary Planes: 𐍈, 𝒜, 🀄, 🚀\n" ~
        "Surrogate Pair Test: 😀👨‍👩‍👧‍👦\n" ~
        "Right-to-Left Text: English مرحبا עברית\n" ~
        "Combining Characters: ñ, à, 🇦🇺\n" ~
        "Whitespace: Space ␣, NBSP , ZWSP​\n" ~
        "Private Use Area: , ﷽, \n" ~
        "Edge Cases: Valid 😊, Invalid: �\n" ~
        "U+E000–U+FFFF Range:  (U+E000), 豈 (U+F900)" ~
        "Control Characters: \u0008 \u001B \u0000\n";

    char[1024] utf8Buffer;
    wchar[512] utf16Buffer;
    dchar[512] utf32Buffer;

    // test all conversions with characters in every significant value range
    size_t utf8Len = uniConvert(unicodeTest, utf8Buffer);                // D-C
    size_t utf16Len = uniConvert(utf8Buffer[0..utf8Len], utf16Buffer);   // C-W
    size_t utf32Len = uniConvert(utf16Buffer[0..utf16Len], utf32Buffer); // W-D
    utf16Len = uniConvert(utf32Buffer[0..utf32Len], utf16Buffer);        // D-W
    utf8Len = uniConvert(utf16Buffer[0..utf16Len], utf8Buffer);          // W-C
    utf32Len = uniConvert(utf8Buffer[0..utf8Len], utf32Buffer);          // C-D
    assert(unicodeTest[] == utf32Buffer[0..utf32Len]);

    // TODO: test all the error cases; invalid characters, buffer overflows, truncated inputs, etc...
    //...
}

