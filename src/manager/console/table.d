module manager.console.table;

import urt.array;
import urt.lifetime : move;
import urt.mem : alloc;
import urt.string.ansi : visible_width, visible_slice;
import urt.time : MonoTime, getTime, seconds;
import urt.variant;

import manager.console.command : Command, CommandCompletionState, CommandState;
import manager.console.session : Session;

import router.stream : FillProducer, max_tx_page, TxStatus;

nothrow @nogc:


struct Table
{
nothrow @nogc:

    enum TextAlign : ubyte { left, right }
    enum gap = 2;
    enum max_cols = 32;

    struct ColumnStats
    {
        size_t[max_cols] natural;
        size_t[max_cols] total;
        uint rows;
    }

    uint num_rows() const pure
        => _num_rows;

    uint num_cols() const pure
        => cast(uint)_columns.length;

    void highlight_row(uint row, const(char)[] prefix = "\x1b[7m", const(char)[] suffix = "\x1b[27m")
    {
        _highlight_row = row;
        _highlight_prefix = prefix;
        _highlight_suffix = suffix;
    }

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

    // render a viewport: header + rows[offset .. offset+viewport_h]
    // sticky_widths: if non-null, column widths only grow (never shrink between frames)
    void render_viewport(Session session, uint offset, uint viewport_h, size_t[] sticky_widths = null)
    {
        immutable num_cols = _columns.length;
        if (num_cols == 0 || session is null)
            return;

        pad_incomplete_row();

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
        clear_rows();
        _highlight_row = uint.max;
    }

    void clear_rows()
    {
        _text_buf.clear();
        _cell_ends.clear();
        _cell_spans.clear();
        _num_rows = 0;
    }

    void measure(ref ColumnStats stats)
    {
        immutable num_cols = _columns.length;
        assert(num_cols <= max_cols);
        pad_incomplete_row();
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
                    if (cell_w > stats.natural[col])
                        stats.natural[col] = cell_w;
                    stats.total[col] += cell_w;
                    ++col;
                }
                else
                    col += (span == 0) ? cast(uint)num_cols - col : span;
            }
        }
        stats.rows += _num_rows;
    }

    // the header widths fold into stats.natural, which format_row then takes
    void fit_widths(ref ColumnStats stats, size_t term_width, size_t[] alloc)
    {
        immutable num_cols = _columns.length;
        assert(num_cols <= max_cols);

        size_t[] natural = stats.natural[];
        size_t[max_cols] avg = void;

        foreach (col; 0 .. num_cols)
        {
            size_t header = visible_width(_columns[col].header);
            if (natural[col] < header)
                natural[col] = header;
            avg[col] = stats.rows > 0 ? (stats.total[col] + stats.rows - 1) / stats.rows : 0;
        }

        foreach (col; 0 .. num_cols)
            alloc[col] = natural[col];
        immutable size_t gap_total = (num_cols > 1) ? (num_cols - 1) * gap : 0;
        if (term_width == 0)
            term_width = 80;

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

    // A cell wider than its column truncates only where the column was fitted below `natural`.
    size_t format_row(char[] buf, const size_t[] widths, int row, const(size_t)[] natural = null)
    {
        import urt.string.ascii : to_upper;

        const num_cols = _columns.length;
        const is_highlighted = row >= 0 && row == _highlight_row;
        const(char)[] suffix = is_highlighted ? _highlight_suffix : null;
        immutable size_t limit = buf.length - 3 - suffix.length;
        size_t pos;

        void put(const(char)[] text, bool upper = false)
        {
            size_t n = text.length < limit - pos ? text.length : limit - pos;
            if (upper)
                to_upper(text[0 .. n], buf[pos .. pos + n]);
            else
                buf[pos .. pos + n] = text[0 .. n];
            pos += n;
        }

        void fill(size_t n)
        {
            if (n > limit - pos)
                n = limit - pos;
            buf[pos .. pos + n] = ' ';
            pos += n;
        }

        if (is_highlighted)
            put(_highlight_prefix);

        char[256] slice_buf = void;
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
            if (vis_w > w && w >= 3 && (natural.length == 0 || w < natural[col]))
            {
                vis_w = w - 2;
                truncated = true;
                text = text.visible_slice(slice_buf, 0, vis_w);
            }

            size_t pad = (w > vis_w + (truncated ? 2 : 0)) ? w - vis_w - (truncated ? 2 : 0) : 0;

            TextAlign alignment = (span == 1) ? _columns[col].alignment : TextAlign.left;

            if (alignment == TextAlign.right)
                fill(pad);

            put(text, is_header);
            if (truncated)
                put("..");

            if (!is_last)
                fill((alignment == TextAlign.left ? pad : 0) + gap);

            col += span_cols;
        }

        buf[pos .. pos + 3] = "\x1b[K";
        pos += 3;
        buf[pos .. pos + suffix.length] = suffix[];
        return pos + suffix.length;
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
    const(char)[] _highlight_prefix;
    const(char)[] _highlight_suffix;
    uint _highlight_row = uint.max;
    uint _num_rows;

    void compute_column_widths(Session session, size_t[] alloc)
    {
        ColumnStats stats;
        measure(stats);
        fit_widths(stats, session.width, alloc);
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
        char[512] buf = void;
        session.write_output(buf[0 .. format_row(buf[], widths, row)], true);
    }
}


// a chunk ends at the last whole block of the shallowest depth it holds, and the next resumes there
abstract class TablePrint : CommandState
{
nothrow @nogc:

    ~this() {}

    this(Session session, Command* command = null)
    {
        super(session, command);
    }

    // finished once the session's stream has taken the last of the output, or at once when cancelled
    override CommandCompletionState update()
    {
        if (!_released && session.output_busy)
            return CommandCompletionState.in_progress;
        finish();
        return CommandCompletionState.finished;
    }

    override void request_cancel()
    {
        finish();
    }

protected:
    Table table;

    abstract void walk();

    // the columns are measured over the first pulls, then the rows are printed from the resume point
    final void start()
    {
        _measuring = true;
        _feed = FillProducer(&produce, max_tx_page);
        session.feed_output(&_feed.produce);
    }

    final uint resume_key() const pure
        => _resume_key;

    final bool stopped() const pure
        => _stopped;

    // keys ascend through a walk; walk() starts from resume_key()
    final void begin_block(uint key)
    {
        _key = key;
        _rows = 0;
        _skip = key == _resume_key ? _resume_rows : 0;
    }

    // true: the row was emitted by an earlier chunk; otherwise fill table's row, then commit_row()
    final bool skip_row()
    {
        if (_stopped)
            return true;
        if (!_measuring && _rows < _skip)
        {
            ++_rows;
            return true;
        }
        table.clear_rows();
        table.add_row();
        return false;
    }

    final void commit_row()
    {
        if (_measuring)
        {
            table.measure(_stats);
            return;
        }
        emit(0);
        if (_stopped)
            return;
        ++_rows;
        mark(ubyte.max, _key, _rows);
        if (getTime() >= _deadline)
            stop();
    }

    final bool row(Args...)(auto ref Args cells)
    {
        if (!skip_row())
        {
            foreach (ref c; cells)
                table.cell(c);
            commit_row();
        }
        return !_stopped;
    }

    // closes a subtree at `depth` below the top-level block; 0 closes the block
    final void end(ubyte depth)
    {
        if (_measuring)
        {
            // measuring resumes at a block, so it stops only at one
            if (depth == 0 && getTime() >= _deadline)
            {
                _resume_key = _key + 1;
                _stopped = true;
            }
            return;
        }
        if (_rows <= _skip)
            return;
        if (depth == 0)
            mark(0, _key + 1, 0);
        else
            mark(depth, _key, _rows);
    }

private:
    enum max_row = 512;

    struct Mark
    {
        size_t len;
        uint key;
        uint rows;
        ubyte depth = ubyte.max;
    }

    FillProducer _feed;
    Table.ColumnStats _stats;
    size_t[Table.max_cols] _widths;
    char[] _chunk;
    size_t _len;
    Mark _mark;
    MonoTime _deadline;
    uint _resume_key;
    uint _resume_rows;
    uint _key;
    uint _rows;
    uint _skip;
    bool _measuring;
    bool _stopped;
    bool _header_sent;
    bool _released;

    size_t produce(char[] chunk, MonoTime deadline, out TxStatus status)
    {
        _deadline = deadline;
        _stopped = false;
        if (_measuring)
        {
            walk();
            if (_stopped)
            {
                status = TxStatus.yield;
                return 0;
            }
            _measuring = false;
            table.fit_widths(_stats, session.width, _widths[0 .. table.num_cols]);
            _resume_key = 0;
        }

        _chunk = chunk;
        _len = 0;
        _mark = Mark();
        if (!_header_sent)
        {
            emit(-1);
            _header_sent = true;
            mark(ubyte.max, _resume_key, _resume_rows);
        }
        walk();
        _chunk = null;
        if (_stopped)
        {
            status = _len ? TxStatus.more : TxStatus.yield;
            return _len;
        }
        status = TxStatus.end;
        return _len;
    }

    // what was made and not taken is dropped, a produced tail included
    void finish()
    {
        _released = true;
        session.release_output(&_feed.produce);
        _feed.release();
    }

    // the chunk ends at its last whole block, which the next chunk resumes from
    void stop()
    {
        _len = _mark.len;
        _resume_key = _mark.key;
        _resume_rows = _mark.rows;
        _stopped = true;
    }

    void mark(ubyte depth, uint key, uint rows)
    {
        if (depth <= _mark.depth)
            _mark = Mark(_len, key, rows, depth);
    }

    void emit(int row)
    {
        char[max_row] line = void;
        size_t room = _chunk.length < line.length ? _chunk.length : line.length;
        size_t n = table.format_row(line[0 .. room - 1], _widths[0 .. table.num_cols], row, _stats.natural[]);
        line[n++] = '\n';
        if (_len + n > _chunk.length)
        {
            debug assert(_len != 0, "a row always fits an empty chunk");
            return stop();
        }
        _chunk[_len .. _len + n] = line[0 .. n];
        _len += n;
    }
}


// prints tables built whole as the session's stream takes them, a second after the first and a blank line;
// the tables' headers must outlive the print
CommandState print_table(Session session, ref Table table)
{
    Table none;
    return alloc!BuiltPrint(session, table, none);
}

CommandState print_table(Session session, ref Table first, ref Table second)
    => alloc!BuiltPrint(session, first, second);

final class BuiltPrint : TablePrint
{
nothrow @nogc:

    ~this() {}

    this(Session session, ref Table first, ref Table second)
    {
        super(session);
        _built = first.move;
        _next = second.move;
        begin();
    }

    override CommandCompletionState update()
    {
        if (super.update() == CommandCompletionState.in_progress)
            return CommandCompletionState.in_progress;
        if (_next.num_cols == 0)
            return CommandCompletionState.finished;
        session.write_line();
        _built = _next.move;
        table.clear();
        _stats = Table.ColumnStats();
        _resume_key = 0;
        _resume_rows = 0;
        _header_sent = false;
        _released = false;
        begin();
        return CommandCompletionState.in_progress;
    }

    override void request_cancel()
    {
        _next.clear();
        super.request_cancel();
    }

protected:
    override void walk()
    {
        immutable uint cols = _built.num_cols;
        for (uint row = resume_key; row < _built.num_rows; ++row)
        {
            begin_block(row);
            if (!skip_row())
            {
                foreach (col; 0 .. cols)
                    table.cell_span(_built.get_cell_text(row, col), _built._cell_spans[row * cols + col]);
                commit_row();
            }
            if (stopped)
                return;
            end(0);
        }
    }

private:
    Table _built;
    Table _next;

    void begin()
    {
        _built.pad_incomplete_row();
        table._columns = _built._columns;
        start();
    }
}

const(char)[] enum_key_for(ref const Variant value)
{
    import urt.meta.enuminfo : VoidEnumInfo;

    const(VoidEnumInfo)* info = value.get_enum_info();
    if (info is null)
        return null;
    return info.key_for_raw(value.asLong);
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

    // TablePrint chunks at the shallowest whole block and never loses or repeats a row
    {
        import urt.mem : alloc, free;
        import urt.mem.temp : tconcat;
        import urt.string : StringLit;
        import manager.collection : Collection;
        import manager.console.command : front_is;
        import manager.console.console : Console;
        import manager.console.session : StringSession;

        static final class TreePrint : TablePrint
        {
        nothrow @nogc:

            ~this() {}

            this(Session session, uint devices, uint components, uint elements)
            {
                super(session);
                _devices = devices;
                _components = components;
                _elements = elements;
                table.add_column("name");
                table.add_column("value");
                _measuring = true;
            }

            override void walk()
            {
                foreach (d; (resume_key ? resume_key : 1) .. _devices + 1)
                {
                    begin_block(d);
                    if (!row(tconcat("device", d), ""))
                        return;
                    foreach (c; 0 .. _components)
                    {
                        if (!row(tconcat("  component", c), ""))
                            return;
                        foreach (e; 0 .. _elements)
                        {
                            if (!row(tconcat("    element", e), "0123456789"))
                                return;
                            end(2);
                        }
                        end(1);
                    }
                    end(0);
                }
            }

            uint _devices, _components, _elements;
        }

        Console* console = alloc!Console(null, StringLit!"test.table-print");
        StringSession session = console.createSession!StringSession();
        scope(exit)
        {
            console.destroy_session(session);
            Collection!Session().update_all();
        }

        static bool ends_at(const(char)[] text, const(char)[] next_row_prefix, size_t offset)
            => offset == text.length || text[offset .. $].front_is(next_row_prefix);

        MonoTime later = getTime() + seconds(3600);
        TxStatus status;
        static immutable uint[3][3] shapes = [[6, 2, 2], [2, 12, 6], [1, 1, 60]];
        static immutable size_t[3] chunk_sizes = [512, 700, 1600];
        foreach (ref shape; shapes)
        {
            TreePrint whole = alloc!TreePrint(session, shape[0], shape[1], shape[2]);
            char[16384] full_buf = void;
            const(char)[] full = full_buf[0 .. whole.produce(full_buf[], later, status)];
            assert(status == TxStatus.end && full.length > 0);
            free(whole);

            immutable uint device_rows = 1 + shape[1] * (shape[2] + 1);
            foreach (chunk_size; chunk_sizes)
            {
                TreePrint paged = alloc!TreePrint(session, shape[0], shape[1], shape[2]);
                Array!char joined;
                char[1600] chunk = void;
                for (status = TxStatus.more; status != TxStatus.end; )
                {
                    size_t n = paged.produce(chunk[0 .. chunk_size], later, status);
                    assert(n > 0 || status == TxStatus.end);
                    size_t at = joined.length;
                    joined ~= chunk[0 .. n];
                    size_t cut = joined.length;
                    if (status == TxStatus.end || at == 0)
                        continue;
                    // a device that fits whole is never split from the chunk before it
                    bool device_cut = ends_at(full, "device", cut);
                    bool component_cut = device_cut || ends_at(full, "  component", cut);
                    if ((device_rows + 1) * 32 < chunk_size)
                        assert(device_cut);
                    else if ((shape[2] + 2) * 32 < chunk_size)
                        assert(component_cut);
                }
                assert(joined[] == full);
                free(paged);
            }

            // out of time on every pull: the columns measure a block at a time, then each pull prints at
            // least a row and stops, and the rows still arrive whole and in order
            TreePrint hurried = alloc!TreePrint(session, shape[0], shape[1], shape[2]);
            Array!char joined;
            char[1600] chunk = void;
            uint pulls;
            for (status = TxStatus.more; status != TxStatus.end; )
            {
                assert(++pulls < 10_000, "a pull out of time made no progress");
                size_t n = hurried.produce(chunk[], getTime(), status);
                assert(n > 0 ? status == TxStatus.more || status == TxStatus.end : status == TxStatus.end || (status == TxStatus.yield && hurried._measuring));
                joined ~= chunk[0 .. n];
            }
            assert(joined[] == full);
            free(hurried);
        }

        TreePrint cancelled = alloc!TreePrint(session, 4, 4, 4);
        char[512] chunk = void;
        assert(cancelled.produce(chunk[], later, status) > 0 && status == TxStatus.more);
        cancelled.request_cancel();
        assert(cancelled._released && cancelled.update() == CommandCompletionState.finished);
        free(cancelled);

        // a table built whole prints through the pull, and a second follows it after a blank line
        session.clearOutput();
        Table first, second;
        first.add_column("key");
        first.add_column("value", Table.TextAlign.right);
        foreach (i; 0 .. 3)
        {
            first.add_row();
            first.cell(tconcat("row", i));
            first.cell(tconcat(i * 100));
        }
        second.add_column("other");
        second.add_row();
        second.cell("last");
        CommandState built = print_table(session, first, second);
        assert(first.num_cols == 0 && built.update() == CommandCompletionState.in_progress);
        assert(built.update() == CommandCompletionState.finished);
        free(built);
        assert(session.getOutput() == "KEY   VALUE\x1b[K\nrow0      0\x1b[K\nrow1    100\x1b[K\nrow2    200\x1b[K\n\nOTHER\x1b[K\nlast\x1b[K\n");
    }
}
