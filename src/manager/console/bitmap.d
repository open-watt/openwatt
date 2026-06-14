module manager.console.bitmap;

// Terminal bitmap rendering.
//
// Bitmap is a small ARGB pixel buffer with basic raster primitives. blit_row
// converts a band of pixels to one row of terminal character cells using
// unicode block mosaics - each cell renders the two pixel colours that best
// represent its block, as foreground/background SGR colour with the partial
// block character whose set-subpixels match the foreground. Alpha 0 pixels
// are transparent: they show the terminal's default background.
//
// Cell resolutions: half = 1x2 pixels per cell (best colour fidelity),
// quadrant = 2x2 (U+2596-259F), sextant = 2x3 (U+1FB00-1FB3B). ascii is a
// 1x2 fallback using only ASCII characters.

import urt.array;
import urt.string;
import urt.string.uni : uni_convert;

nothrow @nogc:


// Pixels are 0xAARRGGBB; alpha 0 = transparent (terminal default background).
alias Pixel = uint;

Pixel rgb(ubyte r, ubyte g, ubyte b) pure
    => 0xFF000000 | (uint(r) << 16) | (uint(g) << 8) | b;

Pixel dim(Pixel p, ubyte percent) pure
{
    uint r = ((p >> 16) & 0xFF) * percent / 100;
    uint g = ((p >> 8) & 0xFF) * percent / 100;
    uint b = (p & 0xFF) * percent / 100;
    return (p & 0xFF000000) | (r << 16) | (g << 8) | b;
}

// 50/50 mix; transparent pixels don't contribute
Pixel mix(Pixel a, Pixel b) pure
{
    if (!(a >> 24))
        return b;
    if (!(b >> 24))
        return a;
    uint r = (((a >> 16) & 0xFF) + ((b >> 16) & 0xFF)) / 2;
    uint g = (((a >> 8) & 0xFF) + ((b >> 8) & 0xFF)) / 2;
    uint bl = ((a & 0xFF) + (b & 0xFF)) / 2;
    return 0xFF000000 | (r << 16) | (g << 8) | bl;
}


enum BlitStyle : ubyte
{
    ascii,    // 1x2, ASCII only
    half,     // 1x2, half blocks
    quadrant, // 2x2, quadrant blocks
    sextant,  // 2x3, sextant mosaics
}

uint blit_cell_width(BlitStyle style) pure
    => style >= BlitStyle.quadrant ? 2 : 1;

uint blit_cell_height(BlitStyle style) pure
    => style == BlitStyle.sextant ? 3 : 2;


struct Bitmap
{
nothrow @nogc:

    uint width, height;

    this(this) @disable;

    void init(uint w, uint h)
    {
        width = w;
        height = h;
        _pixels.resize(w * h);
        clear();
    }

    void clear(Pixel color = 0)
    {
        _pixels[][] = color;
    }

    Pixel get(uint x, uint y) const pure
        => x < width && y < height ? _pixels[y * width + x] : 0;

    void set(uint x, uint y, Pixel color)
    {
        if (x < width && y < height)
            _pixels[][y * width + x] = color;
    }

    // fill a vertical pixel run, inclusive of both ends; blend mixes 50/50
    // with whatever is already there instead of overwriting
    void vfill(uint x, int y0, int y1, Pixel color, bool blend = false)
    {
        if (x >= width)
            return;
        if (y0 > y1)
        {
            int t = y0;
            y0 = y1;
            y1 = t;
        }
        if (y0 < 0)
            y0 = 0;
        if (y1 >= cast(int)height)
            y1 = height - 1;
        foreach (y; y0 .. y1 + 1)
        {
            ref Pixel p = _pixels[][y * width + x];
            p = blend ? mix(p, color) : color;
        }
    }

    void hline(int x0, int x1, int y, Pixel color)
    {
        if (y < 0 || y >= cast(int)height)
            return;
        if (x0 > x1)
        {
            int t = x0;
            x0 = x1;
            x1 = t;
        }
        if (x0 < 0)
            x0 = 0;
        if (x1 >= cast(int)width)
            x1 = width - 1;
        foreach (x; x0 .. x1 + 1)
            _pixels[][y * width + x] = color;
    }

    void line(int x0, int y0, int x1, int y1, Pixel color)
    {
        int dx = x1 > x0 ? x1 - x0 : x0 - x1;
        int dy = y1 > y0 ? y0 - y1 : y1 - y0; // negative magnitude
        int sx = x0 < x1 ? 1 : -1;
        int sy = y0 < y1 ? 1 : -1;
        int err = dx + dy;
        while (true)
        {
            set(x0, y0, color);
            if (x0 == x1 && y0 == y1)
                break;
            int e2 = 2 * err;
            if (e2 >= dy)
            {
                err += dy;
                x0 += sx;
            }
            if (e2 <= dx)
            {
                err += dx;
                y0 += sy;
            }
        }
    }

private:
    Array!Pixel _pixels;
}


// Per-cell override hook: return true to replace the cell's character and
// colours (e.g. smooth graph boundaries, text overlays). `fg`/`bg` arrive
// pre-filled with the blitter's choice; alpha-0 bg means terminal default.
alias CellOverride = bool delegate(uint col, uint row, ref dchar ch, ref Pixel fg, ref Pixel bg) nothrow @nogc;

// Render one row of character cells (cell row `row` covers pixel rows
// [row*cell_h, row*cell_h + cell_h)) and append it to `line`. Emits 24-bit
// SGR colour codes and finishes with SGR reset. `cols` limits output width
// in cells; the bitmap is padded with transparency if it doesn't cover.
void blit_row(ref const Bitmap bmp, BlitStyle style, uint row, uint cols,
              ref MutableString!0 line, scope CellOverride cell_override = null)
{
    uint cw = blit_cell_width(style);
    uint ch = blit_cell_height(style);
    uint py0 = row * ch;

    Pixel cur_fg = 1, cur_bg = 1; // impossible values force initial SGR

    foreach (col; 0 .. cols)
    {
        Pixel[6] px = void;
        foreach (sy; 0 .. ch)
            foreach (sx; 0 .. cw)
                px[sy * cw + sx] = bmp.get(col * cw + sx, py0 + sy);
        uint n = cw * ch;

        Pixel fg, bg;
        uint bits = pick_cell_colors(px[0 .. n], fg, bg);

        dchar c;
        final switch (style)
        {
            case BlitStyle.ascii:
                c = bits == 0 ? ' ' : bits == 1 ? '\'' : bits == 2 ? ',' : '#';
                break;
            case BlitStyle.half:
                c = half_chars[bits];
                break;
            case BlitStyle.quadrant:
                c = quad_chars[bits];
                break;
            case BlitStyle.sextant:
                c = sextant_char(bits);
                break;
        }

        if (cell_override && cell_override(col, row, c, fg, bg))
        {
            // overridden cells supply their own colours
        }

        emit_sgr(line, fg, bg, cur_fg, cur_bg);
        append_utf8(line, c);
    }

    line ~= "\x1b[0m";
}

void append_utf8(ref MutableString!0 s, dchar c)
{
    if (c < 0x80)
    {
        s ~= cast(char)c;
        return;
    }
    char[4] buf = void;
    size_t len = uni_convert((&c)[0 .. 1], buf[]);
    s ~= buf[0 .. len];
}


private:

// Choose the two colours that best represent the cell and assign every
// pixel to one of them; returns the bitmask of foreground pixels (bit n =
// pixel n). Transparent runs as a colour candidate so cells over the
// terminal background stay transparent.
uint pick_cell_colors(const(Pixel)[] px, out Pixel fg, out Pixel bg)
{
    Pixel[6] colors = void;
    uint[6] counts = void;
    uint num;

    foreach (p; px)
    {
        Pixel key = (p >> 24) ? p : 0;
        uint i = 0;
        for (; i < num; ++i)
        {
            if (colors[i] == key)
            {
                ++counts[i];
                break;
            }
        }
        if (i == num)
        {
            colors[num] = key;
            counts[num] = 1;
            ++num;
        }
    }

    // two most frequent candidates
    uint a = 0;
    foreach (i; 1 .. num)
        if (counts[i] > counts[a])
            a = i;
    uint b = uint.max;
    foreach (i; 0 .. num)
    {
        if (i == a)
            continue;
        if (b == uint.max || counts[i] > counts[b])
            b = i;
    }

    Pixel ca = colors[a];
    Pixel cb = b == uint.max ? ca : colors[b];

    // foreground takes the opaque colour; transparent prefers background
    if (ca >> 24)
    {
        fg = ca;
        bg = cb;
    }
    else
    {
        fg = cb;
        bg = ca;
    }
    if (!(fg >> 24) && (bg >> 24))
    {
        fg = bg;
        bg = 0;
    }
    if (!(fg >> 24))
        return 0; // wholly transparent cell

    uint bits;
    foreach (i, p; px)
    {
        Pixel key = (p >> 24) ? p : 0;
        if (key == fg || (key != bg && (fg >> 24) && color_dist(key, fg) < color_dist(key, bg)))
            bits |= 1u << i;
    }
    return bits;
}

uint color_dist(Pixel a, Pixel b) pure
{
    // transparent is infinitely far from any colour
    if ((a >> 24) != (b >> 24))
        return uint.max;
    int dr = cast(int)((a >> 16) & 0xFF) - cast(int)((b >> 16) & 0xFF);
    int dg = cast(int)((a >> 8) & 0xFF) - cast(int)((b >> 8) & 0xFF);
    int db = cast(int)(a & 0xFF) - cast(int)(b & 0xFF);
    return dr * dr * 3 + dg * dg * 6 + db * db;
}

void emit_sgr(ref MutableString!0 line, Pixel fg, Pixel bg, ref Pixel cur_fg, ref Pixel cur_bg)
{
    if (fg != cur_fg)
    {
        if (fg >> 24)
            line.append("\x1b[38;2;", (fg >> 16) & 0xFF, ';', (fg >> 8) & 0xFF, ';', fg & 0xFF, 'm');
        else
            line ~= "\x1b[39m";
        cur_fg = fg;
    }
    if (bg != cur_bg)
    {
        if (bg >> 24)
            line.append("\x1b[48;2;", (bg >> 16) & 0xFF, ';', (bg >> 8) & 0xFF, ';', bg & 0xFF, 'm');
        else
            line ~= "\x1b[49m";
        cur_bg = bg;
    }
}

// half blocks: bit 0 = top, bit 1 = bottom
immutable dchar[4] half_chars = [ ' ', 0x2580, 0x2584, 0x2588 ];

// quadrants: bit 0 = TL, 1 = TR, 2 = BL, 3 = BR
immutable dchar[16] quad_chars = [
    ' ',    0x2598, 0x259D, 0x2580,
    0x2596, 0x258C, 0x259E, 0x259B,
    0x2597, 0x259A, 0x2590, 0x259C,
    0x2584, 0x2599, 0x259F, 0x2588,
];

// sextants: bit 0 = TL, 1 = TR, 2 = ML, 3 = MR, 4 = BL, 5 = BR.
// U+1FB00-1FB3B covers all patterns except empty, left half, right half and
// full block, which live in the legacy block-elements range.
dchar sextant_char(uint bits) pure
{
    if (bits == 0)
        return ' ';
    if (bits == 0b010101)
        return 0x258C; // left half
    if (bits == 0b101010)
        return 0x2590; // right half
    if (bits == 0b111111)
        return 0x2588; // full block
    return 0x1FB00 + bits - 1 - (bits > 0b010101 ? 1 : 0) - (bits > 0b101010 ? 1 : 0);
}


unittest
{
    assert(sextant_char(0b000001) == 0x1FB00);
    assert(sextant_char(0b000010) == 0x1FB01);
    assert(sextant_char(0b010110) == 0x1FB14); // sextants 2,3,5
    assert(sextant_char(0b101011) == 0x1FB28); // sextants 1,2,4,6
    assert(sextant_char(0b111110) == 0x1FB3B);
    assert(sextant_char(0b010101) == 0x258C);
    assert(sextant_char(0b101010) == 0x2590);
    assert(sextant_char(0b111111) == 0x2588);

    Bitmap bmp;
    bmp.init(4, 6);
    bmp.vfill(0, 0, 5, rgb(255, 0, 0));
    bmp.set(2, 0, rgb(0, 255, 0));

    MutableString!0 line;
    blit_row(bmp, BlitStyle.sextant, 0, 2, line);
    assert(line.length > 0);

    // solid column cell = left half block in red on default background
    MutableString!0 expect;
    expect.append("\x1b[38;2;255;0;0m\x1b[49m");
    append_utf8(expect, 0x258C);
    assert(line[][0 .. expect.length] == expect[]);
}
