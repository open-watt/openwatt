module manager.console.table;

import urt.array;
import urt.variant;

import manager.console.session : Session;

nothrow @nogc:


struct Table
{
nothrow @nogc:

    enum TextAlign : ubyte { left, right }
    enum gap = 2;

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
    }

    void cell(ref const Variant value)
    {
        if (value.isNull)
        {
            _cell_ends ~= cast(uint)_text_buf.length;
            return;
        }

        if (value.is_enum)
        {
            const(char)[] name = enum_key_for(value);
            if (name.length > 0)
            {
                _text_buf ~= name;
                _cell_ends ~= cast(uint)_text_buf.length;
                return;
            }
        }

        ptrdiff_t len;
        if (value.isArray || value.isObject)
        {
            // HACK: use json formatter, but I think we want to expand arrays into plain comma separated lists?
            import urt.format.json : write_json;
            len = write_json(value, null, true);
            if (len <= 0)
            {
                _cell_ends ~= cast(uint)_text_buf.length;
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
                return;
            }
            auto buf = _text_buf.extend!false(len);
            value.toString(buf, null, null);
        }
        _cell_ends ~= cast(uint)_text_buf.length;
    }

    void render(Session session)
    {
        immutable num_cols = _columns.length;
        if (num_cols == 0 || session is null)
            return;

        pad_incomplete_row();

        enum max_cols = 32;
        assert(num_cols <= max_cols);

        size_t[max_cols] natural = void;
        size_t[max_cols] col_total = void;
        size_t[max_cols] avg = void;
        size_t[max_cols] alloc = void;

        foreach (col; 0 .. num_cols)
        {
            natural[col] = _columns[col].header.length;
            col_total[col] = 0;
        }
        foreach (row; 0 .. _num_rows)
        {
            foreach (col; 0 .. num_cols)
            {
                size_t cell_len = get_cell_text(row, cast(uint)col).length;
                if (cell_len > natural[col])
                    natural[col] = cell_len;
                col_total[col] += cell_len;
            }
        }
        foreach (col; 0 .. num_cols)
        {
            // compute average widths (should this be median? biased?)
            if (_num_rows > 0)
                avg[col] = (col_total[col] + _num_rows - 1) / _num_rows;
            else
                avg[col] = 0;
        }

        // figure the actual column widths
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

            // phase 1: shrink flexible columns (high variance: max - avg > 2)
            size_t flex_shrinkable = 0;
            foreach (col; 0 .. num_cols)
            {
                if (natural[col] > avg[col] + 2)
                {
                    size_t floor = _columns[col].header.length;
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
                        size_t floor = _columns[col].header.length;
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

                // distribute integer division remainder
                size_t remainder = to_shrink - shrunk;
                foreach (col; 0 .. num_cols)
                {
                    if (remainder == 0)
                        break;
                    if (natural[col] > avg[col] + 2)
                    {
                        size_t floor = _columns[col].header.length;
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

            // phase 2: if still too wide, shrink all columns proportionally
            if (excess > 0)
            {
                size_t total_shrinkable = 0;
                foreach (col; 0 .. num_cols)
                {
                    size_t floor = _columns[col].header.length;
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
                        size_t floor = _columns[col].header.length;
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
                        size_t floor = _columns[col].header.length;
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

        write_row(session, alloc[0 .. num_cols], uint.max);
        foreach (row; 0 .. _num_rows)
            write_row(session, alloc[0 .. num_cols], row);
    }

    void clear()
    {
        _columns.clear();
        _text_buf.clear();
        _cell_ends.clear();
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
    uint _num_rows;

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
            _cell_ends ~= cast(uint)_text_buf.length;
    }

    void write_row(Session session, const size_t[] widths, int row)
    {
        import urt.string.ascii : to_upper;

        const num_cols = _columns.length;
        char[512] buf = void;
        size_t pos;

        foreach (col; 0 .. num_cols)
        {
            const is_header = row < 0;
            const is_last = (col == num_cols - 1);
            const w = widths[col];

            const(char)[] text;
            if (is_header)
                text = _columns[col].header[];
            else
                text = get_cell_text(row, cast(uint)col);

            size_t text_len = text.length;
            bool truncated = false;

            if (text_len > w)
            {
                if (w >= 3)
                {
                    text_len = w - 2;
                    truncated = true;
                }
                else
                    text_len = w;
                text = text[0 .. text_len];
            }

            size_t pad = (w > text_len + (truncated ? 2 : 0)) ? w - text_len - (truncated ? 2 : 0) : 0;

            TextAlign alignment = _columns[col].alignment;

            if (alignment == TextAlign.right)
            {
                buf[pos .. pos + pad] = ' ';
                pos += pad;
            }

            if (is_header)
                to_upper(text[0 .. text_len], buf[pos .. pos + text_len]);
            else
                buf[pos .. pos + text_len] = text[0 .. text_len];
            pos += text_len;
            if (truncated)
                buf[pos++] = '.', buf[pos++] = '.';

            if (!is_last)
            {
                size_t trail = (alignment == TextAlign.left ? pad : 0) + gap;
                buf[pos .. pos + trail] = ' ';
                pos += trail;
            }
        }

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
