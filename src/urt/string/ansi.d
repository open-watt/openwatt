module urt.string.ansi;

import urt;

enum ANSI_ERASE_LINE = "\x1b[2K";
enum ANSI_ERASE_SCREEN = "\x1b[2J";

enum ANSI_ARROW_UP = "\x1b[A";
enum ANSI_ARROW_DOWN = "\x1b[B";
enum ANSI_ARROW_RIGHT = "\x1b[C";
enum ANSI_ARROW_LEFT = "\x1b[D";

enum ANSI_END1 = "\x1b[F";
enum ANSI_HOME1 = "\x1b[H";

enum ANSI_HOME2 = "\x1b[1~";
enum ANSI_DEL = "\x1b[3~";
enum ANSI_END2 = "\x1b[4~";
enum ANSI_PGUP = "\x1b[5~";
enum ANSI_PGDN = "\x1b[6~";
enum ANSI_HOME3 = "\x1b[7~";
enum ANSI_END3 = "\x1b[8~";

enum ANSI_FG_DEFAULT = "\x1b[39m";
enum ANSI_FG_BLACK = "\x1b[30m";
enum ANSI_FG_RED = "\x1b[31m";
enum ANSI_FG_GREEN = "\x1b[32m";
enum ANSI_FG_YELLOW = "\x1b[33m";
enum ANSI_FG_BLUE = "\x1b[34m";
enum ANSI_FG_MAGENTA = "\x1b[35m";
enum ANSI_FG_CYAN = "\x1b[36m";
enum ANSI_FG_WHITE = "\x1b[37m";
enum ANSI_FG_BRIGHT_BLACK = "\x1b[90m";
enum ANSI_FG_BRIGHT_RED = "\x1b[91m";
enum ANSI_FG_BRIGHT_GREEN = "\x1b[92m";
enum ANSI_FG_BRIGHT_YELLOW = "\x1b[93m";
enum ANSI_FG_BRIGHT_BLUE = "\x1b[94m";
enum ANSI_FG_BRIGHT_MAGENTA = "\x1b[95m";
enum ANSI_FG_BRIGHT_CYAN = "\x1b[96m";
enum ANSI_FG_BRIGHT_WHITE = "\x1b[97m";

enum ANSI_BG_DEFAULT = "\x1b[49m";
enum ANSI_BG_BLACK = "\x1b[40m";
enum ANSI_BG_RED = "\x1b[41m";
enum ANSI_BG_GREEN = "\x1b[42m";
enum ANSI_BG_YELLOW = "\x1b[43m";
enum ANSI_BG_BLUE = "\x1b[44m";
enum ANSI_BG_MAGENTA = "\x1b[45m";
enum ANSI_BG_CYAN = "\x1b[46m";
enum ANSI_BG_WHITE = "\x1b[47m";
enum ANSI_BG_BRIGHT_BLACK = "\x1b[100m";
enum ANSI_BG_BRIGHT_RED = "\x1b[101m";
enum ANSI_BG_BRIGHT_GREEN = "\x1b[102m";
enum ANSI_BG_BRIGHT_YELLOW = "\x1b[103m";
enum ANSI_BG_BRIGHT_BLUE = "\x1b[104m";
enum ANSI_BG_BRIGHT_MAGENTA = "\x1b[105m";
enum ANSI_BG_BRIGHT_CYAN = "\x1b[106m";
enum ANSI_BG_BRIGHT_WHITE = "\x1b[107m";

enum ANSI_BOLD = "\x1b[1m";
enum ANSI_FAINT = "\x1b[2m";
enum ANSI_NORMAL = "\x1b[22m";
enum ANSI_UNDERLINE = "\x1b[4m";
enum ANSI_NO_UNDERLINE = "\x1b[24m";

enum ANSI_RESET = "\x1b[0m";


nothrow @nogc:

size_t parseANSICode(const(char)[] text)
{
    import urt.string.ascii : isNumeric;

    if (text.length < 3 || text[0] != '\x1b')
        return 0;
    if (text[1] != '[' && text[1] != 'O')
        return 0;
    size_t i = 2;
    for (; i < text.length && (text[i].isNumeric || text[i] == ';'); ++i)
    {}
    if (i == text.length)
        return 0;
    return i + 1;
}

char[] stripDecoration(char[] text) pure
{
    return stripDecoration(text, text);
}

char[] stripDecoration(const(char)[] text, char[] buffer) pure
{
    size_t len = text.length, outLen = 0;
    char* dst = buffer.ptr;
    const(char)* src = text.ptr;
    bool writeOutput = text.ptr != buffer.ptr;
    for (size_t i = 0; i < len;)
    {
        char c = src[i];
        if (c == '\x1b' && len >= i + 4 && src[i + 1] == '[')
        {
            size_t j = i + 2;
            while (j < len && ((src[j] >= '0' && src[j] <= '9') || src[j] == ';'))
                ++j;
            if (j < len && src[j] == 'm')
            {
                i = j + 1;
                writeOutput = true;
                continue;
            }
        }
        if (BranchMoreExpensiveThanStore || writeOutput)
            dst[outLen] = c; // skip stores where unnecessary (probably the common case)
        ++outLen;
    }
    return buffer[0 .. outLen];
}
