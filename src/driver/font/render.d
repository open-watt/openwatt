// Text into a page-organised mono framebuffer: one byte spans eight rows, LSB at
// the top, which is what ST7565/SSD1306-class panels scan out and what the font
// tables already hold. No panel state here, so this builds and tests on the host.
module driver.font.render;

import urt.string.uni : next_dchar;

import driver.font.small;

nothrow @nogc:


uint text_width(const(char)[] text)
{
    uint width = 0;
    bool first = true;
    while (text.length)
    {
        size_t len;
        dchar c = next_dchar(text, len);
        if (len == 0)
            break;
        text = text[len .. $];
        uint w = font_small_width_of(cast(wchar)c);
        if (w == 0)
            continue;
        width += first ? w : w + font_small_gap;
        first = false;
    }
    return width;
}

// Returns the columns the glyph advances, which is what a caller adds to the pen
// even where the right edge clipped it.
uint draw_glyph(ubyte[] buffer, uint stride, uint pages, uint x, uint y, wchar c)
{
    ubyte[font_small_max_width] columns = void;
    uint width = font_small_glyph(c, columns[]);
    if (width == 0 || x >= stride || y >= pages * 8)
        return width;

    uint visible = width < stride - x ? width : stride - x;
    foreach (i; 0 .. visible)
        write_column(buffer, stride, pages, x + i, y, columns[i]);
    return width;
}

// Draws as much of text as fits in max_width columns, breaking at the last space
// rather than mid-word where there is one. Returns where the next line resumes,
// which equals text.length once the whole string is down. Nothing is drawn past
// max_width; where a single glyph will not fit, one code point is dropped so a
// caller looping on the return value still advances.
size_t draw_text(ubyte[] buffer, uint stride, uint pages, uint x, uint y, const(char)[] text, uint max_width = uint.max)
{
    if (x < stride && max_width > stride - x)
        max_width = stride - x;

    size_t draw_end = text.length, resume = text.length;
    size_t wrap_end = 0, wrap_resume = 0;
    bool wrapped = false, first = true;
    uint width = 0;

    for (size_t i = 0; i < text.length;)
    {
        size_t len;
        dchar c = next_dchar(text[i .. $], len);
        if (len == 0)
            break;

        if (c == '\n')
        {
            draw_end = i;
            resume = i + len;
            break;
        }

        uint w = font_small_width_of(cast(wchar)c);
        if (w)
        {
            uint advance = first ? w : w + font_small_gap;
            if (width + advance > max_width)
            {
                if (c == ' ')
                {
                    draw_end = i;
                    resume = i + len;
                }
                else if (wrapped)
                {
                    draw_end = wrap_end;
                    resume = wrap_resume;
                }
                else
                {
                    draw_end = i;
                    resume = i ? i : len;
                }
                break;
            }
            width += advance;
            first = false;
        }
        if (c == ' ')
        {
            wrapped = true;
            wrap_end = i;
            wrap_resume = i + len;
        }
        i += len;
    }

    uint pen = x;
    bool gap = false;
    for (size_t i = 0; i < draw_end;)
    {
        size_t len;
        dchar c = next_dchar(text[i .. $], len);
        if (len == 0)
            break;
        i += len;
        if (font_small_width_of(cast(wchar)c) == 0)
            continue;
        if (gap && pen < stride)
            write_column(buffer, stride, pages, pen++, y, 0);
        pen += draw_glyph(buffer, stride, pages, pen, y, cast(wchar)c);
        gap = true;
    }
    return resume;
}


private:

// A glyph is exactly one page tall, so a page-aligned y is a plain store and
// anything else splits across two pages.
void write_column(ubyte[] buffer, uint stride, uint pages, uint x, uint y, ubyte bits)
{
    uint page = y >> 3;
    uint shift = y & 7;
    uint base = page * stride + x;
    if (shift == 0)
    {
        buffer[base] = bits;
        return;
    }
    ubyte keep = cast(ubyte)((1 << shift) - 1);
    buffer[base] = cast(ubyte)((buffer[base] & keep) | (bits << shift));
    if (page + 1 < pages)
    {
        uint next = base + stride;
        buffer[next] = cast(ubyte)((buffer[next] & ~keep) | (bits >> (8 - shift)));
    }
}


unittest
{
    enum stride = 64, pages = 3;
    ubyte[stride * pages] fb;

    // a page-aligned glyph lands as its own columns, unshifted
    fb[] = 0;
    ubyte[font_small_max_width] want = void;
    uint w = font_small_glyph('A', want[]);
    assert(draw_glyph(fb[], stride, pages, 0, 0, 'A') == w);
    assert(fb[0 .. w] == want[0 .. w]);

    // the same glyph three rows down splits across two pages and reassembles
    fb[] = 0;
    assert(draw_glyph(fb[], stride, pages, 0, 3, 'A') == w);
    foreach (i; 0 .. w)
    {
        uint got = fb[i] >> 3 | (fb[stride + i] << 5);
        assert((got & 0xFF) == want[i]);
    }

    // writing a column must not disturb the rows above or below it
    fb[] = 0xFF;
    assert(draw_glyph(fb[], stride, pages, 0, 3, ' ') == font_small_width_of(' '));
    assert(fb[0] == 0x07 && fb[stride] == 0xF8);

    assert(text_width("") == 0);
    assert(text_width("A") == font_small_width_of('A'));
    assert(text_width("AB") == font_small_width_of('A') + font_small_gap + font_small_width_of('B'));

    // a string that fits reports itself finished
    fb[] = 0;
    assert(draw_text(fb[], stride, pages, 0, 0, "AB", 64) == 2);

    // and one that does not breaks at the space, dropping it from both lines
    immutable line = "AB CD";
    size_t at = draw_text(fb[], stride, pages, 0, 0, line, text_width("AB CD") - 1);
    assert(line[at .. $] == "CD");

    // no space to break on means a hard break mid-word
    immutable word = "ABCDEF";
    at = draw_text(fb[], stride, pages, 0, 0, word, text_width("ABC"));
    assert(word[at .. $] == "DEF");

    // a newline ends the line and is consumed
    immutable two = "AB\nCD";
    at = draw_text(fb[], stride, pages, 0, 0, two, 64);
    assert(two[at .. $] == "CD");

    // too narrow for any glyph still advances, so a caller's loop terminates
    at = draw_text(fb[], stride, pages, 0, 0, "AB", 1);
    assert(at > 0);

    // clipping at the right edge advances the pen by the full glyph width
    fb[] = 0;
    assert(draw_glyph(fb[], stride, pages, stride - 2, 0, 'A') == w);
}
