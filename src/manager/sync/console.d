module manager.sync.console;

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


package class SyncConsoleStream : Stream
{
    alias Properties = AliasSeq!(Prop!("peer", peer),
                                 Prop!("sequence", sequence));
nothrow @nogc:

    enum type_name = "sync-console";
    enum syncable = false;
    enum chunk_size = 8192;

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
    {
        SyncPeer peer = _peer;
        if (!peer || !peer.running)
            return -1;

        size_t written;
        foreach (part; data)
        {
            const(char)[] output = cast(const(char)[])part;
            while (!output.empty)
            {
                size_t length = output.length < chunk_size ? output.length : chunk_size;
                encoder_for(peer._encoder).encode_console(peer, _seq, SyncConsoleEvent.output, output[0 .. length]);
                written += length;
                output = output[length .. $];
            }
        }
        add_tx_bytes(written);
        return written;
    }

    override TerminalChannel* terminal_channel()
    {
        return &_terminal;
    }

protected:
    override bool validate() const pure
        => _peer !is null && _seq != 0;

    override CompletionStatus shutdown()
    {
        SyncPeer peer = _peer;
        _peer = null;
        get_module!SyncModule.console_stream_closed(peer, _seq, _notify_close);
        return CompletionStatus.complete;
    }

private:
    SyncPeer _peer;
    TerminalChannel _terminal;
    String _terminal_type;
    uint _seq;
    bool _notify_close = true;
}


private class PeerConsoleCommand : CommandState
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
