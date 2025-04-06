module urt.string.ascii;



char[] toLower(const(char)[] str) pure nothrow
{
    return toLower(str, new char[str.length]);
}

char[] toUpper(const(char)[] str) pure nothrow
{
    return toUpper(str, new char[str.length]);
}


nothrow @nogc:

// some character category flags...
// 1 = alpha, 2 = numeric, 4 = white, 8 = newline, 10 = control, 20 = ???, 40 = url, 80 = hex
__gshared immutable ubyte[128] charDetails = [
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x14, 0x18, 0x10, 0x10, 0x18, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x40, 0x00,
    0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x00, 0x00, 0x40,
    0x00, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x00, 0x40, 0x10
];

__gshared immutable char[16] hexDigits = "0123456789ABCDEF";


bool isSpace(char c) pure           => c < 128 && (charDetails[c] & 4);
bool isNewline(char c) pure         => c < 128 && (charDetails[c] & 8);
bool isWhitespace(char c) pure      => c < 128 && (charDetails[c] & 0xC);
bool isAlpha(char c) pure           => c < 128 && (charDetails[c] & 1);
bool isNumeric(char c) pure         => cast(uint)(c - '0') <= 9;
bool isAlphaNumeric(char c) pure    => c < 128 && (charDetails[c] & 3);
bool isHex(char c) pure             => c < 128 && (charDetails[c] & 0x80);
bool isControlChar(char c) pure     => c < 128 && (charDetails[c] & 0x10);
bool isURL(char c) pure             => c < 128 && (charDetails[c] & 0x40);

char toLower(char c) pure
{
    // this is the typical way; which is faster on a weak arch?
//    if (c >= 'A' && c <= 'Z')
//        return c + 32;

    uint i = c - 'A';
    if (i < 26)
        return c | 0x20;
    return c;
}

char toUpper(char c) pure
{
    // this is the typical way; which is faster on a weak arch?
//    if (c >= 'a' && c <= 'z')
//        return c - 32;

    uint i = c - 'a';
    if (i < 26)
        return c ^ 0x20;
    return c;
}

char[] toLower(const(char)[] str, char[] buffer) pure
{
    foreach (i; 0 .. str.length)
        buffer[i] = toLower(str[i]);
    return buffer;
}

char[] toUpper(const(char)[] str, char[] buffer) pure
{
    foreach (i; 0 .. str.length)
        buffer[i] = toUpper(str[i]);
    return buffer;
}

char[] toLower(char[] str) pure
{
    return toLower(str, str);
}

char[] toUpper(char[] str) pure
{
    return toUpper(str, str);
}
