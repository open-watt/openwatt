module manager.sync.console;

import urt.log;
import urt.mem;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.console.command;
import manager.console.session;
import manager.sync;
import manager.sync.encoder;
import manager.sync.peer;

import router.stream;

nothrow @nogc:


alias SyncConsoleHandler = void delegate(uint seq, const(char)[] data, bool closed) nothrow @nogc;

struct PendingSyncConsole
{
    SyncPeer peer;
    SyncConsoleHandler handler;
}


CommandState sync_console(Session session, SyncPeer peer)
{
    if (!peer.running)
    {
        session.write_line("sync peer '", peer.name[], "' is not active");
        return null;
    }
    if (!(peer._remote_caps & SyncCaps.console_session))
    {
        session.write_line("sync peer '", peer.name[], "' has no interactive console capability");
        return null;
    }
    if (get_module!SyncModule.has_open_console(peer))
    {
        session.write_line("sync peer '", peer.name[], "' already has an open console");
        return null;
    }
    return alloc!PeerConsoleCommand(session, peer);
}


final package class SyncConsoleStream : Stream
{
    alias Properties = AliasSeq!(Prop!("peer", peer),
                                 Prop!("sequence", sequence));
nothrow @nogc:

    ~this() {}

    enum type_name = "sync-console";
    enum syncable = false;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!SyncConsoleStream, id, flags);
    }

    final inout(SyncPeer) peer() inout pure
        => _peer;
    final void peer(SyncPeer value)
    {
        _peer = value;
        mark_set!(typeof(this), "peer")();
    }

    final uint sequence() const pure
        => _seq;
    final void sequence(uint value)
    {
        _seq = value;
        mark_set!(typeof(this), "sequence")();
    }

    final void receive_input(const(char)[] data)
    {
        incoming(data, getTime());
    }

    final void set_terminal_state(SyncConsoleTerminal terminal)
    {
        if (_terminal.width != terminal.width || _terminal.height != terminal.height)
            _terminal.pending_events |= TerminalEvents.resized;
        if (_terminal.features != terminal.features || _terminal_type[] != terminal.type)
            _terminal.pending_events |= TerminalEvents.features_changed;

        _terminal.width = terminal.width;
        _terminal.height = terminal.height;
        _terminal.features = terminal.features;
        _terminal_type = terminal.type.make_string();
        _terminal.terminal_type = _terminal_type[];
    }

    final void close_from_peer()
    {
        _notify_close = false;
    }

    final void detach_peer()
    {
        _peer = null;
        _notify_close = false;
    }

    override ptrdiff_t write(const(void[])[] data...)
        => queue_copy(data);

    // the peer's control plane has room again
    final void room_returned()
    {
        drain_tx();
    }

    override TerminalChannel* terminal_channel()
    {
        return &_terminal;
    }

protected:
    override bool validate() const pure
        => _peer !is null && _seq != 0;

    // frames while the peer's control plane has room; the peer wakes the stream when acks or the transport free it
    override ptrdiff_t transmit(const(void)[] data)
    {
        SyncPeer peer = _peer;
        if (!peer || !peer.running)
            return -1;
        SyncEncoder encoder = encoder_for(peer._encoder);
        immutable size_t payload = encoder.console_payload(peer);
        // a frame must hold the widest code point
        if (payload < 4)
        {
            log.warning("peer '", peer.name[], "' segment of ", peer.send_limit, " bytes cannot carry console output");
            return -1;
        }
        const(char)[] text = cast(const(char)[])data;
        size_t taken;
        if (_carry_length)
        {
            // the page keeps the completing bytes until the code point is sent
            if (peer.tx_blocked())
                return stop_short(peer, 0);
            char[4] point = _carry;
            size_t length = _carry_length;
            while (taken < text.length && length < sequence_length(point[0]) && (text[taken] & 0xC0) == 0x80)
                point[length++] = text[taken++];
            if (length < sequence_length(point[0]) && taken == text.length)
            {
                _carry = point;
                _carry_length = cast(ubyte)length;
                return taken;
            }
            if (encoder.encode_console(peer, _seq, SyncConsoleEvent.output, point[0 .. length]) < 0)
                return stop_short(peer, 0);
            _carry_length = 0;
        }
        while (taken < text.length)
        {
            if (peer.tx_blocked())
                return stop_short(peer, taken);
            size_t end = text.length - taken < payload ? text.length : taken + payload;
            size_t cut = incomplete_tail(text[taken .. end]);
            if (end - cut > taken && encoder.encode_console(peer, _seq, SyncConsoleEvent.output, text[taken .. end - cut]) < 0)
                return stop_short(peer, taken);
            taken = end - cut;
            // a code point cut by the page's end completes from the next page
            if (cut && end == text.length)
            {
                _carry[0 .. cut] = text[taken .. end];
                _carry_length = cast(ubyte)cut;
                taken = end;
            }
        }
        add_tx_bytes(taken);
        return taken;
    }

    override Duration tx_retry_interval() const
        => Duration.zero;

    override CompletionStatus shutdown()
    {
        SyncPeer peer = _peer;
        _peer = null;
        get_module!SyncModule.console_stream_closed(peer, _seq, _notify_close);
        return CompletionStatus.complete;
    }

private:
    alias log = Log!"sync.console";

    SyncPeer _peer;
    TerminalChannel _terminal;
    String _terminal_type;
    uint _seq;
    bool _notify_close = true;
    ubyte _carry_length;
    char[4] _carry;

    // a full transport invites the peer back; a full control window waits for the ack that frees it
    size_t stop_short(SyncPeer peer, size_t taken)
    {
        if (peer.tx_full())
            peer.arm_tx();
        add_tx_bytes(taken);
        return taken;
    }
}


private final class PeerConsoleCommand : CommandState
{
nothrow @nogc:

    enum char escape_key = '\x1d';

    this(Session session, SyncPeer peer)
    {
        super(session, null);
        _peer = peer;
        remember_terminal();

        uint seq = get_module!SyncModule.open_console(peer, session.width, session.height, session.features, _terminal_type[], &console_event);
        if (_state >= CommandCompletionState.finished)
            return;
        _seq = seq;
        if (!_seq)
        {
            session.write_line("failed to open console on sync peer '", peer.name[], "'");
            _state = CommandCompletionState.error;
            return;
        }

        session.write_line("Connected to sync peer ", peer.name[], "  (escape: Ctrl-])");
    }

    ~this()
    {
        close(false);
    }

    override bool consumes_input() const pure
        => true;

    override void receive_input(const(char)[] data)
    {
        if (!_seq || _state >= CommandCompletionState.finished)
            return;

        for (size_t i = 0; i < data.length; ++i)
        {
            if (data[i] != escape_key)
                continue;
            if (i)
                get_module!SyncModule.send_console_input(_peer, _seq, data[0 .. i]);
            close(true);
            return;
        }
        get_module!SyncModule.send_console_input(_peer, _seq, data);
    }

    override CommandCompletionState update()
    {
        if (_state < CommandCompletionState.finished && terminal_changed())
        {
            get_module!SyncModule.update_console_terminal(_peer, _seq, session.width, session.height, session.features, session.terminal_type());
            remember_terminal();
        }
        return _state;
    }

    override void request_cancel()
    {
        close(false);
    }

private:
    SyncPeer _peer;
    String _terminal_type;
    uint _seq;
    ushort _width;
    ushort _height;
    ClientFeatures _features;
    CommandCompletionState _state = CommandCompletionState.in_progress;

    void close(bool report)
    {
        if (!_seq)
            return;
        get_module!SyncModule.close_console(_peer, _seq);
        _seq = 0;
        _peer = null;
        if (report)
        {
            session.write_line("");
            session.write_line("[disconnected]");
        }
        _state = CommandCompletionState.finished;
    }

    void console_event(uint seq, const(char)[] data, bool closed)
    {
        if (_seq && seq != _seq)
            return;
        if (data.length)
            session.write_raw(data);
        if (!closed)
            return;

        _seq = 0;
        _peer = null;
        session.write_line("");
        session.write_line("[connection closed]");
        _state = CommandCompletionState.finished;
    }

    bool terminal_changed()
    {
        return _width != session.width || _height != session.height || _features != session.features || _terminal_type[] != session.terminal_type();
    }

    void remember_terminal()
    {
        _width = session.width;
        _height = session.height;
        _features = session.features;
        _terminal_type = session.terminal_type().make_string();
    }
}


private:

size_t sequence_length(char lead) pure
    => lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;

// trailing bytes of a code point the slice ends before completing
size_t incomplete_tail(const(char)[] s) pure
{
    size_t i = s.length;
    while (i > 0 && s.length - i < 3 && (s[i - 1] & 0xC0) == 0x80)
        --i;
    if (i == 0 || s[i - 1] < 0xC0)
        return 0;
    size_t have = s.length - i + 1;
    return have < sequence_length(s[i - 1]) ? have : 0;
}
