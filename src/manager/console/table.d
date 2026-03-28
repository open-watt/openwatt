module manager.console.table;

import urt.array;
import urt.string.ansi : visible_width, visible_slice;
import urt.variant;

import manager.console.session : Session;

nothrow @nogc:


struct Table
{
nothrow @nogc:

    enum TextAlign : ubyte { left, right }
    enum gap = 2;
    enum max_cols = 32;

    void add_column(const(char)[] header, TextAlign alignment = TextAlign.left)
    {
        _columns ~= ColumnDef(header, alignment);
    }

    void add_row()
    {
        pad_incomplete_row();
        ++_num_rows;
    }

    void cell(const(char)[] text)
    {
        _text_buf ~= text;
        _cell_ends ~= cast(uint)_text_buf.length;
        _cell_spans ~= cast(ubyte)1;
    }

    // span=0 means "rest of row"
    void cell_span(const(char)[] text, ubyte span = 0)
    {
        _text_buf ~= text;
        _cell_ends ~= cast(uint)_text_buf.length;
        _cell_spans ~= span;
    }

    void cell(ref const Variant value)
    {
        if (value.isNull)
        {
            _cell_ends ~= cast(uint)_text_buf.length;
            _cell_spans ~= cast(ubyte)1;
            return;
        }

        if (value.is_enum)
        {
            const(char)[] name = enum_key_for(value);
            if (name.length > 0)
            {
                _text_buf ~= name;
                _cell_ends ~= cast(uint)_text_buf.length;
                _cell_spans ~= cast(ubyte)1;
                return;
            }
        }

        ptrdiff_t len;
        if (value.isArray || value.isObject)
        {
            import urt.format.json : write_json;
            len = write_json(value, null, true);
            if (len <= 0)
            {
                _cell_ends ~= cast(uint)_text_buf.length;
                _cell_spans ~= cast(ubyte)1;
                return;
            }
            auto buf = _text_buf.extend!false(len);
            write_json(value, buf, true);
        }
        else
        {
            len = value.toString(null, null, null);
            if (len <= 0)
            {
                _cell_ends ~= cast(uint)_text_buf.length;
                _cell_spans ~= cast(ubyte)1;
                return;
            }
            auto buf = _text_buf.extend!false(len);
            value.toString(buf, null, null);
        }
        _cell_ends ~= cast(uint)_text_buf.length;
        _cell_spans ~= cast(ubyte)1;
    }

    void render(Session session)
    {
        immutable num_cols = _columns.length;
        if (num_cols == 0 || session is null)
            return;

        pad_incomplete_row();

        enum max_cols = 32;
        assert(num_cols <= max_cols);

        size_t[max_cols] alloc = void;
        compute_column_widths(session, alloc[0 .. num_cols]);

        write_row(session, alloc[0 .. num_cols], uint.max);
        foreach (row; 0 .. _num_rows)
            write_row(session, alloc[0 .. num_cols], row);
    }

    // render a viewport: header + rows[offset .. offset+viewport_h]
    // sticky_widths: if non-null, column widths only grow (never shrink between frames)
    void render_viewport(Session session, uint offset, uint viewport_h, size_t[] sticky_widths = null)
    {
        immutable num_cols = _columns.length;
        if (num_cols == 0 || session is null)
            return;

        pad_incomplete_row();

        enum max_cols = 32;
        assert(num_cols <= max_cols);

        size_t[max_cols] alloc = void;
        compute_column_widths(session, alloc[0 .. num_cols]);

        if (sticky_widths.length >= num_cols)
        {
            foreach (col; 0 .. num_cols)
            {
                if (alloc[col] < sticky_widths[col])
                    alloc[col] = sticky_widths[col];
                sticky_widths[col] = alloc[col];
            }
        }

        write_row(session, alloc[0 .. num_cols], uint.max);

        uint end = offset + viewport_h;
        if (end > _num_rows)
            end = _num_rows;
        foreach (row; offset .. end)
        {
            session.write_output("\x1b[2K", false);
            write_row(session, alloc[0 .. num_cols], row);
        }
    }

    void clear()
    {
        _columns.clear();
        _text_buf.clear();
        _cell_ends.clear();
        _cell_spans.clear();
        _num_rows = 0;
    }

private:

    struct ColumnDef
    {
        const(char)[] header;
        TextAlign alignment;
    }

    Array!ColumnDef _columns;
    Array!char _text_buf;
    Array!uint _cell_ends;
    Array!ubyte _cell_spans;
    uint _num_rows;

    void compute_column_widths(Session session, size_t[] alloc)
    {
        immutable num_cols = _columns.length;
        enum max_cols = 32;

        size_t[max_cols] natural = void;
        size_t[max_cols] col_total = void;
        size_t[max_cols] avg = void;

        foreach (col; 0 .. num_cols)
        {
            natural[col] = visible_width(_columns[col].header);
            col_total[col] = 0;
        }
        foreach (row; 0 .. _num_rows)
        {
            uint col = 0;
            while (col < num_cols)
            {
                uint idx = row * cast(uint)num_cols + col;
                ubyte span = _cell_spans[idx];
                if (span == 1)
                {
                    size_t cell_w = visible_width(get_cell_text(row, col));
                    if (cell_w > natural[col])
                        natural[col] = cell_w;
                    col_total[col] += cell_w;
                    ++col;
                }
                else
                {
                    uint skip = (span == 0) ? cast(uint)num_cols - col : span;
                    col += skip;
                }
            }
        }
        foreach (col; 0 .. num_cols)
        {
            if (_num_rows > 0)
                avg[col] = (col_total[col] + _num_rows - 1) / _num_rows;
            else
                avg[col] = 0;
        }

        foreach (col; 0 .. num_cols)
            alloc[col] = natural[col];
        immutable size_t gap_total = (num_cols > 1) ? (num_cols - 1) * gap : 0;
        immutable size_t term_width = session.width > 0 ? session.width : 80;

        size_t content_width = gap_total;
        foreach (col; 0 .. num_cols)
            content_width += alloc[col];

        if (content_width > term_width)
        {
            size_t excess = content_width - term_width;

            size_t flex_shrinkable = 0;
            foreach (col; 0 .. num_cols)
            {
                if (natural[col] > avg[col] + 2)
                {
                    size_t floor = visible_width(_columns[col].header);
                    if (avg[col] > floor)
                        floor = avg[col];
                    if (alloc[col] > floor)
                        flex_shrinkable += alloc[col] - floor;
                }
            }

            if (flex_shrinkable > 0)
            {
                size_t to_shrink = excess;
                if (to_shrink > flex_shrinkable)
                    to_shrink = flex_shrinkable;

                size_t shrunk = 0;
                foreach (col; 0 .. num_cols)
                {
                    if (natural[col] > avg[col] + 2)
                    {
                        size_t floor = visible_width(_columns[col].header);
                        if (avg[col] > floor)
                            floor = avg[col];
                        if (alloc[col] > floor)
                        {
                            size_t headroom = alloc[col] - floor;
                            size_t share = headroom * to_shrink / flex_shrinkable;
                            alloc[col] -= share;
                            shrunk += share;
                        }
                    }
                }

                size_t remainder = to_shrink - shrunk;
                foreach (col; 0 .. num_cols)
                {
                    if (remainder == 0)
                        break;
                    if (natural[col] > avg[col] + 2)
                    {
                        size_t floor = visible_width(_columns[col].header);
                        if (avg[col] > floor)
                            floor = avg[col];
                        if (alloc[col] > floor)
                        {
                            --alloc[col];
                            --remainder;
                        }
                    }
                }

                excess -= to_shrink;
            }

            if (excess > 0)
            {
                size_t total_shrinkable = 0;
                foreach (col; 0 .. num_cols)
                {
                    size_t floor = visible_width(_columns[col].header);
                    if (floor == 0)
                        floor = 1;
                    if (alloc[col] > floor)
                        total_shrinkable += alloc[col] - floor;
                }

                if (total_shrinkable > 0)
                {
                    size_t to_shrink = excess;
                    if (to_shrink > total_shrinkable)
                        to_shrink = total_shrinkable;

                    size_t shrunk = 0;
                    foreach (col; 0 .. num_cols)
                    {
                        size_t floor = visible_width(_columns[col].header);
                        if (floor == 0)
                            floor = 1;
                        if (alloc[col] > floor)
                        {
                            size_t headroom = alloc[col] - floor;
                            size_t share = headroom * to_shrink / total_shrinkable;
                            alloc[col] -= share;
                            shrunk += share;
                        }
                    }

                    size_t remainder = to_shrink - shrunk;
                    foreach (col; 0 .. num_cols)
                    {
                        if (remainder == 0)
                            break;
                        size_t floor = visible_width(_columns[col].header);
                        if (floor == 0)
                            floor = 1;
                        if (alloc[col] > floor)
                        {
                            --alloc[col];
                            --remainder;
                        }
                    }
                }
            }
        }

        // Final safety clamp: ensure total never exceeds terminal width
        content_width = gap_total;
        foreach (col; 0 .. num_cols)
            content_width += alloc[col];
        while (content_width > term_width)
        {
            // Remove 1 char from the widest column that's above floor
            size_t widest = 0;
            size_t widest_col = num_cols;
            foreach (col; 0 .. num_cols)
            {
                size_t floor = visible_width(_columns[col].header);
                if (floor == 0)
                    floor = 1;
                if (alloc[col] > floor && alloc[col] > widest)
                {
                    widest = alloc[col];
                    widest_col = col;
                }
            }
            if (widest_col >= num_cols)
                break;
            --alloc[widest_col];
            --content_width;
        }
    }

    const(char)[] get_cell_text(uint row, uint col)
    {
        uint idx = row * cast(uint)_columns.length + col;
        uint start = (idx == 0) ? 0 : _cell_ends[idx - 1];
        uint end = _cell_ends[idx];
        return _text_buf[start .. end];
    }

    void pad_incomplete_row()
    {
        if (_num_rows == 0)
            return;
        size_t expected = _num_rows * _columns.length;
        while (_cell_ends.length < expected)
        {
            _cell_ends ~= cast(uint)_text_buf.length;
            _cell_spans ~= cast(ubyte)1;
        }
    }

    void write_row(Session session, const size_t[] widths, int row)
    {
        import urt.string.ascii : to_upper;

        const num_cols = _columns.length;
        char[512] buf = void;
        size_t pos;

        uint col = 0;
        while (col < num_cols)
        {
            const is_header = row < 0;

            ubyte span = 1;
            if (!is_header)
            {
                uint idx = row * cast(uint)num_cols + col;
                span = _cell_spans[idx];
            }

            // Compute total width for this cell (including spanned columns + gaps)
            uint span_cols = (span == 0) ? cast(uint)num_cols - col : span;
            size_t w = 0;
            foreach (c; col .. col + span_cols)
                w += widths[c];
            if (span_cols > 1)
                w += (span_cols - 1) * gap;

            const is_last = (col + span_cols >= num_cols);

            const(char)[] text;
            if (is_header)
                text = _columns[col].header[];
            else
                text = get_cell_text(row, col);

            size_t vis_w = visible_width(text);
            bool truncated = false;

            // TODO: truncation with visible_width needs byte-level truncation
            // that respects UTF-8/ANSI boundaries. For now, only truncate if
            // the visible width exceeds the column width.
            if (vis_w > w && w >= 3)
            {
                vis_w = w - 2;
                truncated = true;
                char[256] slice_buf = void;
                text = text.visible_slice(slice_buf, 0, vis_w);
            }

            size_t pad = (w > vis_w + (truncated ? 2 : 0)) ? w - vis_w - (truncated ? 2 : 0) : 0;

            TextAlign alignment = (span == 1) ? _columns[col].alignment : TextAlign.left;

            if (alignment == TextAlign.right)
            {
                buf[pos .. pos + pad] = ' ';
                pos += pad;
            }

            if (is_header)
                to_upper(text, buf[pos .. pos + text.length]);
            else
                buf[pos .. pos + text.length] = text;
            pos += text.length;
            if (truncated)
                buf[pos++] = '.', buf[pos++] = '.';

            if (!is_last)
            {
                size_t trail = (alignment == TextAlign.left ? pad : 0) + gap;
                buf[pos .. pos + trail] = ' ';
                pos += trail;
            }

            col += span_cols;
        }

        buf[pos .. pos + 3] = "\x1b[K";
        pos += 3;
        session.write_output(buf[0 .. pos], true);
    }
}

const(char)[] enum_key_for(ref const Variant value)
{
    import urt.meta.enuminfo : VoidEnumInfo;

    const(VoidEnumInfo)* info = value.get_enum_info();
    if (info is null)
        return null;

    // HACK: iterate all entries, we should fix the lookup to make it variant-compatible somehow...
    long v = value.asLong;
    foreach (i; 0 .. info.count)
    {
        const(char)[] key = info.key_by_sorted_index(i);
        Variant kv = info.value_for(key);
        if (!kv.isNull && kv.asLong == v)
            return key;
    }
    return null;
}


unittest
{
    // Test get_cell_text indexing
    {
        Table t;
        t.add_column("A");
        t.add_column("B");

        t.add_row();
        t.cell("hello");
        t.cell("world");

        t.add_row();
        t.cell("foo");
        t.cell("bar");

        t.pad_incomplete_row();

        assert(t.get_cell_text(0, 0) == "hello");
        assert(t.get_cell_text(0, 1) == "world");
        assert(t.get_cell_text(1, 0) == "foo");
        assert(t.get_cell_text(1, 1) == "bar");

        t.clear();
    }

    // Test empty cells
    {
        Table t;
        t.add_column("X");
        t.add_column("Y");

        t.add_row();
        t.cell("data");
        t.cell("");

        t.pad_incomplete_row();

        assert(t.get_cell_text(0, 0) == "data");
        assert(t.get_cell_text(0, 1) == "");

        t.clear();
    }

    // Test padding incomplete row
    {
        Table t;
        t.add_column("A");
        t.add_column("B");
        t.add_column("C");

        t.add_row();
        t.cell("only_one");
        // Missing B and C cells

        t.pad_incomplete_row();

        assert(t.get_cell_text(0, 0) == "only_one");
        assert(t.get_cell_text(0, 1) == "");
        assert(t.get_cell_text(0, 2) == "");

        t.clear();
    }
}
