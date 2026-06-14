module manager.console.graph;

// Time-series graph renderer for the terminal.
//
// Renders one or more series into a Bitmap (sample-and-hold semantics -
// element samples are change events, so values hold until the next sample)
// and blits it with manager.console.bitmap. Multi-series support:
//
//   overlay - every series fills from the baseline in its own colour;
//             overlapping regions blend 50/50, which reads like translucent
//             area charts (the energy-dashboard look).
//   stack   - series stack into cumulative bands, each band its own colour.
//
// In smooth mode (sextant style) fill boundaries are replaced with diagonal
// block-mosaic wedges (U+1FB3C-1FB67) and lower-eighth blocks, which takes
// the staircase out of the fill edge. Stacked bands use the band above as
// the wedge background so interior boundaries stay smooth too.
//
// Output is a row of styled text lines (legend + y-axis gutter + plot +
// time axis) suitable for printing directly or feeding a live view.

import urt.array;
import urt.conv : format_float;
import urt.string;
import urt.time;

import manager.console.bitmap;

nothrow @nogc:


// user-facing style selector: smooth = sextant blit + wedge-smoothed boundary
enum GraphStyle : ubyte
{
    ascii,
    half,
    quadrant,
    sextant,
    smooth,
}

void apply_style(ref GraphOptions opt, GraphStyle style)
{
    final switch (style)
    {
        case GraphStyle.ascii:    opt.style = BlitStyle.ascii;    opt.smooth = false; break;
        case GraphStyle.half:     opt.style = BlitStyle.half;     opt.smooth = false; break;
        case GraphStyle.quadrant: opt.style = BlitStyle.quadrant; opt.smooth = false; break;
        case GraphStyle.sextant:  opt.style = BlitStyle.sextant;  opt.smooth = false; break;
        case GraphStyle.smooth:   opt.style = BlitStyle.sextant;  opt.smooth = true;  break;
    }
}

enum GraphMode : ubyte
{
    overlay, // series fill from the baseline; overlaps blend
    stack,   // cumulative bands
    panels,  // separate charts sharing the time range (handled by the caller)
}

struct GraphOptions
{
    BlitStyle style = BlitStyle.sextant;
    GraphMode mode = GraphMode.overlay;
    bool smooth = true;          // wedge-smoothed fill boundary (sextant style only)
    bool fill = true;            // area fill below the series; false = line only
    bool x_axis = true;          // time rule + labels at the bottom
    bool legend = true;          // colour-keyed legend row when more than one series
    Pixel color = 0;             // single-series colour; 0 = first palette entry
    double y_min;                // fixed scale overrides; NaN = autoscale
    double y_max;
}

struct GraphSeries(S)
{
    const(S)[] samples;
    Pixel color;             // 0 = palette colour by series index
    const(char)[] label;
}

immutable Pixel[8] graph_palette = [
    rgb(110, 200, 255),  // sky
    rgb(255, 170, 80),   // orange
    rgb(140, 230, 120),  // green
    rgb(235, 130, 220),  // magenta
    rgb(250, 220, 100),  // yellow
    rgb(130, 140, 255),  // violet
    rgb(120, 220, 210),  // teal
    rgb(255, 120, 120),  // red
];


// single-series convenience
void render_graph(S)(ref Array!(MutableString!0) lines, const(S)[] samples,
                     ulong t0, ulong t1, uint cols, uint rows, ref const GraphOptions opt)
{
    GraphSeries!S[1] series = [GraphSeries!S(samples, opt.color ? opt.color : graph_palette[0], null)];
    render_graph(lines, series[], t0, t1, cols, rows, opt);
}

// Render `series` over [t0, t1] (unix ns) into `lines`, sized cols x rows
// character cells including legend and axes. S needs `.time` (unix ns) and
// `.value`.
void render_graph(S)(ref Array!(MutableString!0) lines, GraphSeries!S[] series,
                     ulong t0, ulong t1, uint cols, uint rows, ref const GraphOptions opt)
{
    static struct Cursor
    {
        const(S)[] samples;
        size_t idx;

        // sample-and-hold; `t` must not decrease between calls
        bool eval(ulong t, out double v) nothrow @nogc
        {
            if (samples.length == 0 || t < samples[0].time)
                return false;
            while (idx + 1 < samples.length && samples[idx + 1].time <= t)
                ++idx;
            v = samples[idx].value;
            return true;
        }
    }

    lines.clear();

    uint n = cast(uint)series.length;
    bool stacked = opt.mode == GraphMode.stack;
    uint legend_rows = (n > 1 && opt.legend) ? 1 : 0;
    uint axis_rows = opt.x_axis ? 2 : 0;

    if (n == 0 || t1 <= t0 || rows < legend_rows + axis_rows + 2 || cols < 16)
    {
        lines.pushBack() ~= "graph: area too small";
        return;
    }

    Array!Cursor cursors;
    cursors.resize(n);
    Array!Pixel colors;
    colors.resize(n);
    foreach (i; 0 .. n)
    {
        cursors[][i].samples = series[i].samples;
        colors[][i] = series[i].color ? series[i].color : graph_palette[i % graph_palette.length];
    }

    void reset_cursors()
    {
        foreach (ref c; cursors[])
            c.idx = 0;
    }

    uint plot_rows = rows - legend_rows - axis_rows;

    // y range: autoscale over the visible window. For stacked mode the
    // extremes live on the cumulative prefix levels, so sweep coarsely
    // through time; for overlay the raw samples suffice.
    double lo = opt.y_min, hi = opt.y_max;
    if (lo != lo || hi != hi)
    {
        double mn = double.max, mx = -double.max;
        if (stacked)
        {
            mn = 0;
            mx = 0;
            enum steps = 256;
            foreach (s; 0 .. steps + 1)
            {
                ulong t = t0 + (t1 - t0) * s / steps;
                double cum = 0;
                foreach (i; 0 .. n)
                {
                    double v;
                    if (cursors[][i].eval(t, v))
                    {
                        cum += v;
                        mn = mn < cum ? mn : cum;
                        mx = mx > cum ? mx : cum;
                    }
                }
            }
            reset_cursors();
        }
        else
        {
            foreach (i; 0 .. n)
            {
                double v;
                if (cursors[][i].eval(t0, v))
                {
                    mn = mn < v ? mn : v;
                    mx = mx > v ? mx : v;
                }
                foreach (ref s; series[i].samples)
                {
                    if (s.time < t0 || s.time > t1)
                        continue;
                    mn = mn < s.value ? mn : s.value;
                    mx = mx > s.value ? mx : s.value;
                }
            }
            reset_cursors();
        }
        if (mn > mx)
        {
            mn = 0;
            mx = 1;
        }
        double pad = (mx - mn) * 0.05;
        if (pad == 0)
            pad = mx == 0 ? 1 : (mx < 0 ? -mx : mx) * 0.05;
        if (lo != lo)
            lo = mn == 0 ? 0 : mn - pad; // keep a hard zero baseline
        if (hi != hi)
            hi = mx + pad;
    }
    if (hi <= lo)
        hi = lo + 1;

    uint label_every = plot_rows <= 6 ? 2 : (plot_rows <= 16 ? 4 : 6);

    // gutter width from the widest row label
    char[32] fbuf = void;
    size_t label_w = 0;
    for (uint r = 0; r < plot_rows; r += label_every)
    {
        size_t len = format_value(row_value(r, plot_rows, lo, hi), fbuf);
        if (len > label_w)
            label_w = len;
    }
    uint gutter = cast(uint)label_w + 1;
    if (cols < gutter + 8)
    {
        lines.pushBack() ~= "graph: area too small";
        return;
    }
    uint plot_cols = cols - gutter;

    uint cw = blit_cell_width(opt.style);
    uint chh = blit_cell_height(opt.style);
    uint pw = plot_cols * cw;
    uint ph = plot_rows * chh;

    Bitmap bmp;
    bmp.init(pw, ph);

    int value_to_py(double v)
    {
        double f = (v - lo) / (hi - lo);
        return cast(int)(ph - 1 - f * (ph - 1) + 0.5);
    }

    // rasterise
    Array!int prev_py;
    prev_py.resize(n);
    prev_py[][] = int.min;

    foreach (x; 0 .. pw)
    {
        ulong t = t0 + (t1 - t0) * (x * 2 + 1) / (pw * 2);
        if (stacked)
        {
            double cum = 0;
            int y_prev = value_to_py(0);
            foreach (i; 0 .. n)
            {
                double v;
                if (!cursors[][i].eval(t, v) || v == 0)
                    continue;
                cum += v;
                int y = value_to_py(cum);
                bmp.vfill(x, y, y_prev, colors[i]);
                y_prev = y;
            }
        }
        else foreach (i; 0 .. n)
        {
            double v;
            if (!cursors[][i].eval(t, v))
            {
                prev_py[][i] = int.min;
                continue;
            }
            int py = value_to_py(v);
            if (opt.fill)
                bmp.vfill(x, py, ph - 1, colors[i], n > 1);
            else
            {
                int prev = prev_py[i];
                if (prev != int.min && (py > prev + 1 || py < prev - 1))
                    bmp.line(cast(int)x - 1, prev, x, py, colors[i]);
                else
                    bmp.set(x, py < 0 ? 0 : py, colors[i]);
                prev_py[][i] = py;
            }
        }
    }
    reset_cursors();

    // fill-height fraction (0..1 of plot height) per series at each
    // cell-column edge, for the smooth boundary pass. Stacked mode stores
    // cumulative levels; NaN where there's no data.
    Array!double edges;
    bool smooth = opt.smooth && opt.fill && opt.style == BlitStyle.sextant;
    if (smooth)
    {
        edges.resize(n * (plot_cols + 1));
        foreach (c; 0 .. plot_cols + 1)
        {
            ulong t = t0 + (t1 - t0) * (c * cw) / pw;
            if (t > t1)
                t = t1;
            double cum = 0;
            bool any = false;
            foreach (i; 0 .. n)
            {
                double v;
                if (cursors[][i].eval(t, v))
                {
                    any = true;
                    cum = stacked ? cum + v : v;
                    edges[][i * (plot_cols + 1) + c] = (cum - lo) / (hi - lo);
                }
                else
                    edges[][i * (plot_cols + 1) + c] = stacked && any
                        ? (cum - lo) / (hi - lo) : double.nan;
            }
        }
        reset_cursors();
    }

    SmoothBoundary boundary;
    boundary.edges = edges[];
    boundary.colors = colors[];
    boundary.n = n;
    boundary.plot_cols = plot_cols;
    boundary.plot_rows = plot_rows;
    boundary.stacked = stacked;

    // legend
    if (legend_rows)
    {
        ref MutableString!0 line = lines.pushBack();
        foreach (i; 0 .. n)
        {
            Pixel c = colors[i];
            line.append("\x1b[38;2;", (c >> 16) & 0xFF, ';', (c >> 8) & 0xFF, ';', c & 0xFF, 'm');
            append_utf8(line, 0x25A0); // ■
            line ~= "\x1b[0m ";
            if (series[i].label.length)
                line ~= series[i].label;
            if (i + 1 < n)
                line ~= "  ";
        }
    }

    // plot rows: label gutter + axis + cells
    foreach (r; 0 .. plot_rows)
    {
        ref MutableString!0 line = lines.pushBack();
        if (r % label_every == 0)
        {
            size_t len = format_value(row_value(r, plot_rows, lo, hi), fbuf);
            foreach (i; len .. label_w)
                line ~= ' ';
            line ~= fbuf[0 .. len];
            line ~= "┤";
        }
        else
        {
            foreach (i; 0 .. label_w)
                line ~= ' ';
            line ~= "│";
        }
        blit_row(bmp, opt.style, r, plot_cols, line, smooth ? &boundary.cell : null);
    }

    if (!opt.x_axis)
        return;

    // x axis rule
    {
        ref MutableString!0 line = lines.pushBack();
        foreach (i; 0 .. label_w)
            line ~= ' ';
        line ~= "└";
        foreach (c; 1 .. plot_cols)
            line ~= (c == plot_cols / 2 || c == plot_cols - 1) ? "┴" : "─";
    }

    // time labels: start, centre, end
    {
        ref MutableString!0 line = lines.pushBack();
        char[8] tbuf = void, tbuf2 = void, tbuf3 = void;
        const(char)[] lt = format_time(t0, tbuf);
        const(char)[] ct = format_time(t0 + (t1 - t0) / 2, tbuf2);
        const(char)[] rt = format_time(t1, tbuf3);

        uint w = gutter + plot_cols;
        uint cpos = gutter + plot_cols / 2 - cast(uint)ct.length / 2;
        uint rpos = w - cast(uint)rt.length;

        foreach (i; 0 .. gutter)
            line ~= ' ';
        line ~= lt;
        uint pos = gutter + cast(uint)lt.length;
        for (; pos < cpos; ++pos)
            line ~= ' ';
        if (pos == cpos && cpos + ct.length <= rpos)
        {
            line ~= ct;
            pos += ct.length;
        }
        for (; pos < rpos; ++pos)
            line ~= ' ';
        if (pos == rpos)
            line ~= rt;
    }
}


// value for the vertical centre of a plot cell row
double row_value(uint row, uint rows, double lo, double hi) pure
    => hi - (row + 0.5) / rows * (hi - lo);

// compact value formatting with k/M scaling
size_t format_value(double v, char[] buf)
{
    double a = v < 0 ? -v : v;
    char suffix = 0;
    if (a >= 1_000_000)
    {
        v /= 1_000_000;
        suffix = 'M';
    }
    else if (a >= 10_000)
    {
        v /= 1000;
        suffix = 'k';
    }
    ptrdiff_t len = format_float(v, buf, ".4");
    if (len < 0)
        return 0;
    if (suffix)
        buf[len++] = suffix;
    return len;
}


private:

// CellOverride context for the smooth fill boundary: picks a diagonal wedge
// (or eighth block when flat) for cells a fill boundary passes through.
// Overlay skips cells where another series intrudes (those stay raster);
// stacked bands use the band above as the wedge background.
struct SmoothBoundary
{
nothrow @nogc:

    const(double)[] edges;  // n * (plot_cols + 1) fill fractions
    const(Pixel)[] colors;
    uint n;
    uint plot_cols;
    uint plot_rows;
    bool stacked;

    bool cell(uint col, uint row, ref dchar ch, ref Pixel fg, ref Pixel bg)
    {
        double cell_bot = cast(double)(plot_rows - 1 - row) / plot_rows;

        // clipped fill fractions of series i within this cell
        bool clipped(uint i, out double lf, out double rf)
        {
            double hl = edges[i * (plot_cols + 1) + col];
            double hr = edges[i * (plot_cols + 1) + col + 1];
            if (hl != hl || hr != hr)
                return false;
            lf = (hl - cell_bot) * plot_rows;
            rf = (hr - cell_bot) * plot_rows;
            lf = lf < 0 ? 0 : (lf > 1 ? 1 : lf);
            rf = rf < 0 ? 0 : (rf > 1 ? 1 : rf);
            return true;
        }

        if (stacked)
        {
            // topmost band boundary crossing this cell wins; the band above
            // becomes the wedge background
            for (uint i = n; i-- > 0; )
            {
                double lf, rf;
                if (!clipped(i, lf, rf))
                    continue;
                if ((lf <= 0 && rf <= 0) || (lf >= 1 && rf >= 1))
                    continue;
                fg = colors[i];
                bg = i + 1 < n ? colors[i + 1] : 0;
                set_boundary_char(ch, lf, rf);
                return true;
            }
            return false;
        }

        // overlay: wedge only when exactly one series occupies the cell
        uint present = uint.max;
        double lf, rf;
        foreach (i; 0 .. n)
        {
            double l, r;
            if (!clipped(i, l, r) || (l <= 0 && r <= 0))
                continue;
            if (present != uint.max)
                return false; // contested cell - leave it to the raster
            present = i;
            lf = l;
            rf = r;
        }
        if (present == uint.max || (lf >= 1 && rf >= 1))
            return false;
        fg = colors[present];
        bg = 0;
        set_boundary_char(ch, lf, rf);
        return true;
    }

    static void set_boundary_char(ref dchar ch, double lf, double rf)
    {
        uint l3 = cast(uint)(lf * 3 + 0.5);
        uint r3 = cast(uint)(rf * 3 + 0.5);
        if (l3 == r3)
        {
            uint e = cast(uint)((lf + rf) * 4 + 0.5); // eighths
            ch = e == 0 ? ' ' : cast(dchar)(0x2580 + e);
        }
        else
            ch = wedge_chars[l3 * 4 + r3];
    }
}

const(char)[] format_time(ulong unix_ns, char[] buf)
{
    DateTime dt = getDateTime(from_unix_time_ns(unix_ns));
    buf[0] = cast(char)('0' + dt.hour / 10);
    buf[1] = cast(char)('0' + dt.hour % 10);
    buf[2] = ':';
    buf[3] = cast(char)('0' + dt.minute / 10);
    buf[4] = cast(char)('0' + dt.minute % 10);
    buf[5] = ':';
    buf[6] = cast(char)('0' + dt.second / 10);
    buf[7] = cast(char)('0' + dt.second % 10);
    return buf[0 .. 8];
}

// fill-below diagonal wedges indexed [left_third * 4 + right_third]; the
// equal-thirds diagonal entries are unused (flat cells use eighth blocks)
immutable dchar[16] wedge_chars = [
    ' ',     0x1FB48, 0x1FB4A, 0x25E2,
    0x1FB3D, 0x2581,  0x1FB46, 0x1FB44,
    0x1FB3F, 0x1FB51, 0x2584,  0x1FB42,
    0x25E3,  0x1FB4F, 0x1FB4D, 0x2588,
];


unittest
{
    static struct TestSample
    {
        ulong time;
        double value;
    }

    TestSample[4] data = [
        TestSample(1_000, 1.0),
        TestSample(2_000, 5.0),
        TestSample(3_000, 3.0),
        TestSample(4_000, 8.0),
    ];
    TestSample[2] data2 = [
        TestSample(1_000, 2.0),
        TestSample(2_500, 6.0),
    ];

    Array!(MutableString!0) lines;
    GraphOptions opt;

    // single series: no legend row
    render_graph(lines, data[], 1_000, 4_000, 60, 16, opt);
    assert(lines.length == 16);

    import urt.string : endsWith;
    foreach (i; 0 .. 14)
        assert(lines[i][].endsWith("\x1b[0m"));

    // two series overlaid: legend + plot + axis still fills the row budget
    GraphSeries!TestSample[2] multi = [
        GraphSeries!TestSample(data[], 0, "a"),
        GraphSeries!TestSample(data2[], 0, "b"),
    ];
    render_graph(lines, multi[], 1_000, 4_000, 60, 16, opt);
    assert(lines.length == 16);

    // stacked
    opt.mode = GraphMode.stack;
    render_graph(lines, multi[], 1_000, 4_000, 60, 16, opt);
    assert(lines.length == 16);

    // no data renders without crashing
    render_graph(lines, data[0 .. 0], 1_000, 4_000, 60, 16, opt);
    assert(lines.length == 16);
}
