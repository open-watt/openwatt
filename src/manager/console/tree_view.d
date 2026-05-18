module manager.console.tree_view;

import urt.array;
import urt.string;
import urt.string.ansi;

import manager.console.command;
import manager.console.live_view;
import manager.console.session;
import manager.console.table;

nothrow @nogc:


struct TreeNodeInfo
{
    const(char)[] id;            // stable key for expansion state
    const(char)[] label;         // first-column text (TreeView prepends prefix)
    uint depth;
    bool is_last_sibling;
    bool has_children;
}

alias TreeYield = bool delegate(ref const TreeNodeInfo info, scope void delegate(ref Table) nothrow @nogc render_extra_cells) nothrow @nogc;


abstract class TreeViewState : LiveViewState
{
nothrow @nogc:

    this(Session session, Command command)
    {
        super(session, command);
        _follow = false;
    }

    abstract void configure_columns(ref Table table);
    abstract void walk_tree(scope TreeYield yield);

    bool default_expanded(const(char)[])
        => _default_expand;

    @property bool default_expand() const pure
        => _default_expand;
    @property void default_expand(bool v)
    {
        _default_expand = v;
    }

    final override uint content_height()
    {
        rebuild();
        return cast(uint)_rows.length;
    }

    final override uint header_rows()
        => 1;

    final override void render_content(uint offset, uint count, uint width)
    {
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }
        rebuild();
        resolve_cursor();

        if ((session.features & ClientFeatures.cursor) && _cursor_row < _rows.length)
            _table.highlight_row(_cursor_row);

        _table.render_viewport(session, offset, count, _sticky_widths[]);
    }

    final override const(char)[] status_text()
    {
        import urt.string.format : tformat;
        return tformat("{0} rows | up/down=move +/-=expand", cast(uint)_rows.length);
    }

protected:

    final override bool handle_key(const(char)[] seq)
    {
        if (seq[] == ANSI_ARROW_UP)
        {
            move_cursor(-1);
            return true;
        }
        if (seq[] == ANSI_ARROW_DOWN)
        {
            move_cursor(1);
            return true;
        }
        if (seq[] == ANSI_ARROW_RIGHT)
        {
            handle_expand();
            return true;
        }
        if (seq[] == ANSI_ARROW_LEFT)
        {
            handle_collapse();
            return true;
        }
        if (seq.length == 1 && (seq[0] == ' ' || seq[0] == '\r' || seq[0] == '\n'))
        {
            toggle_current();
            return true;
        }
        return false;
    }

    final override CommandCompletionState update()
    {
        _rebuilt = false;
        return super.update();
    }

private:

    struct RowInfo
    {
        uint id_start;
        uint id_end;
        uint depth;
        bool has_children;
    }

    Table _table;
    Array!RowInfo _rows;
    Array!char _id_pool;
    Array!bool _ancestor_last;
    Array!char _prefix_buf;
    Array!char _expanded_keys;
    Array!uint _expanded_ends;
    Array!char _cursor_id;
    uint _cursor_row;
    size_t[Table.max_cols] _sticky_widths;
    uint _prev_width;
    bool _rebuilt;
    bool _default_expand;

    const(char)[] row_id(size_t i) const pure
        => _id_pool[_rows[i].id_start .. _rows[i].id_end];

    bool is_expanded(const(char)[] id)
    {
        bool def = default_expanded(id);
        bool in_map = find_expanded(id) != size_t.max;
        return in_map ? !def : def;
    }

    size_t find_expanded(const(char)[] id) const pure
    {
        uint start = 0;
        foreach (i, end; _expanded_ends[])
        {
            if (_expanded_keys[start .. end] == id)
                return i;
            start = end;
        }
        return size_t.max;
    }

    void set_expanded(const(char)[] id, bool expanded)
    {
        size_t idx = find_expanded(id);
        bool default_state = default_expanded(id);

        if (expanded == default_state)
        {
            // remove override if present
            if (idx == size_t.max)
                return;
            uint start = idx == 0 ? 0 : _expanded_ends[idx - 1];
            uint end = _expanded_ends[idx];
            uint len = end - start;
            _expanded_keys.remove(start, len);
            _expanded_ends.remove(idx);
            foreach (ref e; _expanded_ends[idx .. $])
                e -= len;
            return;
        }
        if (idx != size_t.max)
            return;
        _expanded_keys ~= id;
        _expanded_ends ~= cast(uint)_expanded_keys.length;
    }

    void rebuild()
    {
        if (_rebuilt)
            return;
        _rebuilt = true;

        _table.clear();
        _table.add_column("");
        configure_columns(_table);

        _rows.clear();
        _id_pool.clear();
        _ancestor_last.clear();

        walk_tree(&emit_row);
    }

    bool emit_row(ref const TreeNodeInfo info, scope void delegate(ref Table) nothrow @nogc render_extra)
    {
        if (_ancestor_last.length > info.depth)
            _ancestor_last.resize(info.depth);

        _prefix_buf.clear();
        if (info.depth > 0)
        {
            foreach (i; 1 .. info.depth)
                _prefix_buf ~= (_ancestor_last[i] ? "   " : "│  ");
            _prefix_buf ~= (info.is_last_sibling ? "└─" : "├─");
        }

        bool expanded = is_expanded(info.id);
        if (info.has_children)
            _prefix_buf ~= expanded ? "[-] " : "[+] ";
        else if (info.depth > 0)
            _prefix_buf ~= "    ";
        _prefix_buf ~= info.label;

        uint id_start = cast(uint)_id_pool.length;
        _id_pool ~= info.id;
        _rows ~= RowInfo(id_start, cast(uint)_id_pool.length, info.depth, info.has_children);

        _table.add_row();
        _table.cell(_prefix_buf[]);
        render_extra(_table);

        _ancestor_last ~= info.is_last_sibling;
        return expanded;
    }

    void resolve_cursor()
    {
        if (_rows.length == 0)
        {
            _cursor_row = 0;
            return;
        }
        if (_cursor_id.length > 0)
        {
            foreach (i; 0 .. _rows.length)
            {
                if (row_id(i) == _cursor_id[])
                {
                    _cursor_row = cast(uint)i;
                    return;
                }
            }
        }
        const uint len = cast(uint)_rows.length;
        if (_cursor_row >= len)
            _cursor_row = len - 1;
        save_cursor_id();
    }

    void save_cursor_id()
    {
        _cursor_id.clear();
        _cursor_id ~= row_id(_cursor_row);
    }

    void move_cursor(int delta)
    {
        rebuild();
        resolve_cursor();
        if (_rows.length == 0)
            return;
        long target = cast(long)_cursor_row + delta;
        if (target < 0)
            target = 0;
        if (target >= _rows.length)
            target = cast(long)_rows.length - 1;
        _cursor_row = cast(uint)target;
        save_cursor_id();
        ensure_visible(_cursor_row);
    }

    void handle_expand()
    {
        rebuild();
        resolve_cursor();
        if (_rows.length == 0)
            return;
        auto row = _rows[_cursor_row];
        if (!row.has_children)
            return;
        const(char)[] id = row_id(_cursor_row);
        if (is_expanded(id))
        {
            // Move to first child if there is one
            if (_cursor_row + 1 < _rows.length && _rows[_cursor_row + 1].depth > row.depth)
            {
                ++_cursor_row;
                save_cursor_id();
                ensure_visible(_cursor_row);
            }
        }
        else
        {
            set_expanded(id, true);
        }
    }

    void handle_collapse()
    {
        rebuild();
        resolve_cursor();
        if (_rows.length == 0)
            return;
        auto row = _rows[_cursor_row];
        const(char)[] id = row_id(_cursor_row);
        if (row.has_children && is_expanded(id))
        {
            set_expanded(id, false);
            return;
        }
        // Jump to parent (last row above with smaller depth)
        if (row.depth == 0)
            return;
        for (uint i = _cursor_row; i > 0; --i)
        {
            if (_rows[i - 1].depth < row.depth)
            {
                _cursor_row = i - 1;
                save_cursor_id();
                ensure_visible(_cursor_row);
                return;
            }
        }
    }

    void toggle_current()
    {
        rebuild();
        resolve_cursor();
        if (_rows.length == 0)
            return;
        auto row = _rows[_cursor_row];
        if (!row.has_children)
            return;
        const(char)[] id = row_id(_cursor_row);
        set_expanded(id, !is_expanded(id));
    }
}
