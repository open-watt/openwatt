module manager.console.live_view;

import urt.array;
import urt.string;
import urt.string.ansi;
import urt.time;
import urt.util : min;

import manager.console.command;
import manager.console.session;

nothrow @nogc:


enum LiveViewMode : ubyte
{
    auto_,       // fullscreen if cursor support, dumb fallback otherwise
    fullscreen,  // alternate screen, absolute positioning
    inline_,     // cursor-up rewrite, last render persists on exit
}

class LiveViewState : CommandState
{
nothrow @nogc:

    this(Session session, Command command, LiveViewMode mode = LiveViewMode.auto_)
    {
        super(session, command);
        _has_cursor = (session.features & ClientFeatures.cursor) != 0;
        _mode = mode;
        _deferred_auto = (_mode == LiveViewMode.auto_);
    }

    abstract uint content_height();

    abstract void render_content(uint offset, uint count, uint width);

protected:

    const(char)[] status_text()
        => null;

    bool handle_key(const(char)[] seq)
        => false;

    override CommandCompletionState update()
    {
        if (_cancelled)
        {
            leave();
            return CommandCompletionState.cancelled;
        }

        if (_deferred_auto)
        {
            _deferred_auto = false;
            if (_has_cursor)
            {
                uint ch = content_height();
                uint h = session.height();
                // +1 for status bar
                _mode = (ch + 1 >= h) ? LiveViewMode.fullscreen : LiveViewMode.inline_;
            }
            if (_mode == LiveViewMode.fullscreen && _has_cursor)
                session.write_output("\x1b[?1049h\x1b[2J\x1b[?25l", false);
        }

        if (!process_input())
        {
            leave();
            return CommandCompletionState.finished;
        }

        if (_has_cursor)
        {
            if (_mode == LiveViewMode.fullscreen)
                draw_fullscreen();
            else
                draw_inline();
        }
        else
            draw_dumb();

        return CommandCompletionState.in_progress;
    }

    override void request_cancel()
    {
        _cancelled = true;
    }

protected:
    uint _scroll_offset;
    bool _follow = true;

private:
    LiveViewMode _mode;
    bool _has_cursor;
    bool _cancelled;
    bool _deferred_auto;
    uint _prev_inline_height;
    MonoTime _last_dumb_print;

    bool process_input()
    {
        char[64] buf = void;
        auto n = session.read_input(buf[]);
        if (n <= 0)
            return true;

        for (size_t i = 0; i < n; ++i)
        {
            if (buf[i] == 'q' || buf[i] == '\x03')
                return false;

            if (size_t ansi_len = parse_ansi_code(buf[i .. n]))
            {
                const(char)[] seq = buf[i .. i + ansi_len];
                auto page = session.height() > 2 ? session.height() - 2 : 1;

                if (seq[] == ANSI_ARROW_UP)
                {
                    if (_scroll_offset > 0)
                        --_scroll_offset;
                    _follow = false;
                }
                else if (seq[] == ANSI_ARROW_DOWN)
                {
                    ++_scroll_offset;
                    uint ch = content_height();
                    uint vh = visible_height();
                    if (ch > vh && _scroll_offset >= ch - vh)
                        _follow = true;
                }
                else if (seq[] == ANSI_PGUP)
                {
                    _scroll_offset = _scroll_offset > page ? _scroll_offset - page : 0;
                    _follow = false;
                }
                else if (seq[] == ANSI_PGDN)
                    _scroll_offset += page;
                else if (seq[] == ANSI_HOME1 || seq[] == ANSI_HOME2 || seq[] == ANSI_HOME3)
                {
                    _scroll_offset = 0;
                    _follow = false;
                }
                else if (seq[] == ANSI_END1 || seq[] == ANSI_END2 || seq[] == ANSI_END3)
                    _follow = true;
                else
                    handle_key(seq);

                i += ansi_len - 1;
            }
        }
        return true;
    }

    uint visible_height()
    {
        uint h = session.height();
        if (_mode == LiveViewMode.fullscreen)
            return h > 2 ? h - 1 : 1;
        else
            return h > 2 ? h - 2 : 1;
    }

    void clamp_scroll()
    {
        uint ch = content_height();
        uint vh = visible_height();
        if (_follow && ch > vh)
            _scroll_offset = ch - vh;
        if (ch > vh && _scroll_offset > ch - vh)
            _scroll_offset = ch - vh;
        if (ch <= vh)
            _scroll_offset = 0;
    }

    void draw_fullscreen()
    {
        import urt.string.format : tformat;

        auto h = session.height();
        auto w = session.width();
        if (h < 3 || w < 10)
            return;

        uint vh = visible_height();
        uint ch = content_height();
        clamp_scroll();

        session.write_output("\x1b[?25l\x1b[1;1H", false);
        uint count = ch > vh ? vh : ch;
        render_content(_scroll_offset, count, w);

        // clear gap between content and status bar
        for (uint i = count; i < vh; ++i)
            session.write_output("\x1b[K\n", false);

        // status bar at last row
        session.write_output(tformat("\x1b[{0};1H\x1b[7m\x1b[K", h), false);
        const(char)[] extra = status_text();
        if (extra)
            session.write_output(tformat(" {0} | rows {1}-{2} of {3} | q=quit up/down=scroll",
                extra, _scroll_offset + 1, _scroll_offset + count, ch), false);
        else
            session.write_output(tformat(" rows {0}-{1} of {2} | q=quit up/down=scroll",
                _scroll_offset + 1, _scroll_offset + count, ch), false);
        session.write_output("\x1b[0m\x1b[?25h", false);
    }

    void draw_inline()
    {
        import urt.string.format : tformat;

        auto w = session.width();
        uint vh = visible_height();
        uint ch = content_height();
        clamp_scroll();

        if (_prev_inline_height > 0)
        {
            session.write_output(tformat("\x1b[{0}A", _prev_inline_height), false);
            session.write_output("\r", false);
        }

        uint count = ch > vh ? vh : ch;
        render_content(_scroll_offset, count, w);

        if (count < _prev_inline_height)
        {
            for (uint i = count; i < _prev_inline_height; ++i)
                session.write_output("\x1b[2K\n", false);
        }

        _prev_inline_height = count;
    }

    void draw_dumb()
    {
        auto now = getTime();
        if (_last_dumb_print != MonoTime.init && now - _last_dumb_print < 2.seconds)
            return;
        _last_dumb_print = now;

        session.write_output("", true);
        uint ch = content_height();
        render_content(0, ch, session.width());
    }

    void leave()
    {
        if (_mode == LiveViewMode.fullscreen && _has_cursor)
            session.write_output("\x1b[?25h\x1b[?1049l", false);
        else if (_has_cursor)
            session.write_output("\x1b[?25h", false);
    }
}


class TextViewState : LiveViewState
{
nothrow @nogc:

    alias LineArray = Array!(MutableString!0);

    this(Session session, Command command, LineArray* lines, bool word_wrap = false, LiveViewMode mode = LiveViewMode.auto_)
    {
        super(session, command, mode);
        _lines = lines;
        _word_wrap = word_wrap;
        _follow = true;
    }

    override uint content_height()
    {
        if (_word_wrap)
        {
            uint total = 0;
            auto w = session.width();
            if (w == 0) w = 80;
            foreach (ref line; (*_lines)[])
            {
                uint len = cast(uint)line.length;
                total += len == 0 ? 1 : (len + w - 1) / w;
            }
            return total;
        }
        return cast(uint)_lines.length;
    }

    override void render_content(uint offset, uint count, uint width)
    {
        if (_word_wrap)
            draw_wrapped(offset, count, width);
        else
            draw_scrollable(offset, count, width);
    }

    override const(char)[] status_text()
    {
        import urt.mem.temp : tconcat;
        uint total = cast(uint)_lines.length;
        if (_word_wrap)
            return tconcat(total, " lines (wrapped)");
        return tconcat(total, " lines");
    }

    // left/right for horizontal scroll in non-word-wrapped mode
    override bool handle_key(const(char)[] seq)
    {
        if (_word_wrap)
            return false;

        if (seq[] == ANSI_ARROW_LEFT)
        {
            if (_h_scroll > 0)
                --_h_scroll;
            return true;
        }
        if (seq[] == ANSI_ARROW_RIGHT)
        {
            ++_h_scroll;
            return true;
        }
        return false;
    }

private:
    LineArray* _lines;
    bool _word_wrap;
    uint _h_scroll;

    void draw_wrapped(uint offset, uint count, uint width)
    {
        if (width == 0) width = 80;

        uint wrapped_line = 0;
        uint src_line = 0;
        uint sub_offset = 0;

        while (src_line < _lines.length && wrapped_line < offset)
        {
            uint len = cast(uint)(*_lines)[src_line].length;
            uint lines_for = len == 0 ? 1 : (len + width - 1) / width;
            if (wrapped_line + lines_for > offset)
            {
                sub_offset = (offset - wrapped_line) * width;
                wrapped_line = offset;
                break;
            }
            wrapped_line += lines_for;
            ++src_line;
        }

        uint drawn = 0;
        while (drawn < count && src_line < _lines.length)
        {
            const(char)[] text = (*_lines)[src_line][];
            uint pos = sub_offset;
            sub_offset = 0;

            if (text.length == 0)
            {
                session.write_output("\x1b[2K", false);
                session.write_output("", true);
                ++drawn;
            }
            else
            {
                while (pos < text.length && drawn < count)
                {
                    uint end = pos + width;
                    if (end > text.length) end = cast(uint)text.length;
                    session.write_output("\x1b[2K", false);
                    session.write_output(text[pos .. end], true);
                    pos = end;
                    ++drawn;
                }
            }
            ++src_line;
        }

        while (drawn < count)
        {
            session.write_output("\x1b[2K", false);
            session.write_output("", true);
            ++drawn;
        }
    }

    void draw_scrollable(uint offset, uint count, uint width)
    {
        foreach (i; offset .. offset + count)
        {
            session.write_output("\x1b[2K", false);
            if (i < _lines.length)
            {
                const(char)[] text = (*_lines)[i][];
                if (_h_scroll < text.length)
                {
                    uint end = _h_scroll + width;
                    if (end > text.length) end = cast(uint)text.length;
                    session.write_output(text[_h_scroll .. end], true);
                }
                else
                    session.write_output("", true);
            }
            else
                session.write_output("", true);
        }
    }
}
