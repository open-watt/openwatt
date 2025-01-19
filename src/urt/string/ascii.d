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

// 1 = alpha, 2 = numeric, 4 = white, 8 = newline
immutable char[128] charDetails = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 8, 0, 0, 8, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0
];


bool isNewline(char c) pure         => c < 128 && (charDetails[c] & 8);
bool isWhitespace(char c) pure      => c < 128 && (charDetails[c] & 0xC);
bool isAlpha(char c) pure           => c < 128 && (charDetails[c] & 1);
bool isNumeric(char c) pure         => c - '0' <= 9;
bool isAlphaNumeric(char c) pure    => c < 128 && (charDetails[c] & 3);
bool isHex(char c) pure             => c.isAlphaNumeric && (c | 0x20) <= 'f';


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
