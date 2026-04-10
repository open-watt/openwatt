---
name: console-session
description: Console session architecture — unified Session backed by any Stream, TerminalChannel side-channel, TelnetStream/ConsoleStream protocol factoring. Use when working on console sessions, terminal I/O, or adding new session transports.
---

# Console Session Architecture

Target architecture for OpenWatt's console session system. Sessions provide interactive command-line access over any transport. The design separates protocol-specific framing (Telnet IAC, SSH channels, local terminal modes) from the universal session logic (input buffering, command execution, history, tab completion).

## Design Principles

1. **One Session class** — all transports use the same Session, backed by a Stream
2. **Protocol lives in the Stream** — TelnetStream strips IAC, ConsoleStream wraps stdin/stdout, SSHStream handles SSH framing
3. **Side-channel for OOB data** — terminal size, echo mode, features, break signals flow through TerminalChannel, not mixed into the byte stream
4. **Streams are composable** — TelnetStream wraps TCPStream, SSHStream wraps TCPStream; the Session doesn't know or care what's underneath

## File Map

| File | Role |
|------|------|
| `src/manager/console/session.d` | **Session** — unified console session, input processing, command execution, history, echo |
| `src/manager/console/console.d` | **Console** — session management, command dispatch, scope tree |
| `src/router/stream/package.d` | **Stream** base — adds `terminal_channel()` virtual (returns null by default) |
| `src/router/stream/console.d` | **ConsoleStream** — platform stdin/stdout as a Stream with TerminalChannel |
| `src/protocol/telnet/stream.d` | **TelnetStream** — wraps any Stream, strips/injects IAC sequences, populates TerminalChannel |
| `src/protocol/telnet/server.d` | **TelnetServer** — accepts TCP connections, creates TelnetStream + Session pairs |

## TerminalChannel

The side-channel between a protocol-aware stream and the Session. Carries out-of-band terminal state that doesn't belong in the data path.

```d
// Defined in src/manager/console/session.d (or a shared location)

struct TerminalChannel
{
    // Terminal dimensions (updated by stream, polled by session)
    uint width = 80;
    uint height = 24;

    // Client capabilities (set during protocol negotiation)
    ClientFeatures features;

    // Terminal type string (e.g. "xterm-256color")
    const(char)[] terminal_type;

    // Pending events (bitfield, set by stream, cleared by session)
    TerminalEvents pending_events;
}

enum TerminalEvents : ubyte
{
    none        = 0,
    resized     = 1 << 0,   // width/height changed
    interrupt   = 1 << 1,   // Ctrl+C / BRK / IP
    erase_char  = 1 << 2,   // EC (telnet erase character)
    erase_line  = 1 << 3,   // EL (telnet erase line)
}
```

### Design Rationale

**Why a struct, not callbacks?** OpenWatt is frame-based (20Hz update loop). Session polls the channel each frame. Events are rare (resize, break) — a bitfield checked once per frame is simpler and cheaper than delegate dispatch. No allocation, no ordering issues, no lifetime concerns.

**Why on Stream, not Session?** The stream is the protocol boundary. TelnetStream knows about IAC NAWS; Session doesn't. ConsoleStream knows about `SIGWINCH` and `GetConsoleScreenBufferInfo`; Session doesn't. The stream populates the channel as a side-effect of its normal `read()` processing.

### Stream Base Integration

```d
// In Stream base class
abstract class Stream : BaseObject
{
    // ... existing read/write/pending/flush API ...

    // Optional terminal side-channel. Non-terminal streams return null.
    TerminalChannel* terminal_channel() { return null; }

    // Optional push callback — called when bytes arrive, instead of polling read().
    // Returns number of bytes consumed; unconsumed tail is retained by the stream
    // and prepended to the next callback invocation.
    alias DataCallback = size_t delegate(const(ubyte)[] data) nothrow @nogc;
    void set_data_callback(DataCallback cb) { _data_callback = cb; }

protected:
    DataCallback _data_callback;
}
```

The push callback allows streams to notify consumers immediately when data arrives, rather than requiring frame-rate polling. When set, the stream calls the callback from within its own `update()` or I/O handler. The return value indicates how many bytes the consumer processed — the stream retains any unconsumed tail and prepends it to the next invocation. This handles partial-parse scenarios (e.g. incomplete ANSI sequences) without the consumer needing its own tail buffer.

Streams that support terminal semantics override this to return their channel. Session checks once at construction and caches the pointer.

## Session (Unified)

Single class handling all transports. Backed by an optional Stream for I/O. Features are read from the stream's TerminalChannel at construction.

### Internal Structure

Session's input processing is split into clear methods:

| Method | Responsibility |
|--------|---------------|
| `update()` | Read from stream, poll terminal events, poll async commands |
| `receive_input()` | Route input to active command (buffer) or line editor (`append_input`) |
| `append_input()` | Parse ANSI sequences and control chars, dispatch to editing/history/completion helpers, call `echo_diff` |
| `handle_ansi_sequence()` | Cursor movement, delete, home/end, word skip |
| `history_prev()` / `history_next()` | Arrow up/down history navigation |
| `handle_tab_completion()` | Tab completion and suggestion display |
| `echo_diff()` | Compute minimal ANSI output to reflect buffer changes |
| `clear_line()` | Erase current line (ANSI) |
| `send_prompt_and_buffer()` | Redraw prompt + buffer with cursor positioning |

### Input Ownership Model

Input belongs to whoever is currently consuming it:

- **Active command running**: Input is buffered raw. The command has agency over the display and the input stream — it may read interactively (scroll, confirm), or ignore input entirely. Session does not echo, parse ANSI, or edit during this time.
- **Ctrl+C (break)**: Cancels the current command. Input before the break was "for" that command and is discarded. Input after the break goes to the next consumer.
- **Script execution**: Multiple commands from a script execute sequentially. Each command gets its turn at the input. Break cancels the current command; the next command starts and may consume further input. A second break cancels the second command.
- **No active command**: Input flows through `append_input` for line editing with full ANSI parsing, cursor movement, echo, and history. Line submit (`\r`/`\n`) triggers command execution.
- **After command completes**: Any remaining buffered input (including raw ANSI sequences accumulated during execution) is fed back through `receive_input` for normal processing.

### Write Output

```d
void write_output(const(char)[] text, bool newline)
{
    if (_stream)
    {
        if (text.length > 0)
            _stream.write(text);
        if (newline)
            _stream.write("\r\n");
    }
}
```

Session always writes `\r\n` for newlines. Streams are transparent byte pipes — no outbound translation. `StringSession` overrides this to capture output to a buffer (used for API command execution).

### Command I/O API

Commands that need interactive input use `read_input` to consume bytes from the session's buffer:

```d
// Session API for commands
ptrdiff_t read_input(void[] buffer);     // consume bytes from input buffer
void write_output(const(char)[] text, bool newline);  // write to terminal
ushort width();                           // terminal width
ushort height();                          // terminal height
ClientFeatures features();                // terminal capabilities
```

Commands that need full line editing (embedded REPL, cascading shell) create an inner Session backed by a PipeStream rather than implementing their own editor.

### PipeStream — Cascading Terminals and Inner Sessions

A PipeStream bridges an inner Session's I/O through an outer Session's command:

```d
class PipeStream : Stream
{
    Session _outer;

    override ptrdiff_t read(void[] buffer)
        // consume from outer session's input buffer via read_input

    override ptrdiff_t write(const(void[])[] data...)
        // forward to outer session's write_output

    override TerminalChannel* terminal_channel()
        => _outer._stream ? _outer._stream.terminal_channel() : null;
}
```

The inner Session automatically gets the human's terminal dimensions, features, and resize events because `terminal_channel()` delegates to the outermost stream's channel. No propagation needed.

| Use case | Inner Session backed by |
|----------|------------------------|
| Embedded REPL / interactive command | PipeStream → outer Session |
| Cascading shell (remote instance) | PipeStream → outer Session → remote |
| Telnet client command | TelnetStream → TCPStream |

### Authentication

Login is implemented as a command, not a framework feature. TelnetServer injects it on connection:

```
TelnetServer.acceptConnection:
    session = createSession(telnet_stream)
    if requires_auth:
        session.set_input("/system/login\r")
```

The `/system/login` command:
1. Prompts for username/password (writes prompts, reads via `read_input`)
2. No echo during execution — password is invisible (standard command behavior)
3. **On Ctrl+C**: closes the session (disconnect — not "skip auth")
4. **On failure**: retry or close session
5. **On success**:
   - Sets session auth state (`session.set_user(user)`)
   - Loads user history (`session.load_history(".history_" ~ username)`)
   - Injects user startup script into buffer (`session._buffer ~= user.startup_script`)
   - Returns complete — session processes startup script, then goes interactive

### Lifecycle

In `main.d`, one Session + ConsoleStream handles both startup config and interactive mode:
1. Session created with ConsoleStream, prompt disabled
2. Config text fed via `set_input()` — processed through `receive_input`
3. When `is_idle()` (no commands, buffer empty), prompt enabled, history loaded
4. Same session, same stream, whole lifecycle

### StringSession

`StringSession` overrides `write_output` to capture output to a buffer instead of writing to a stream. Used for API command execution (HTTP `/api` endpoint) where the response body is the command output. No stream, no terminal channel.

## TelnetStream

Wraps any Stream (typically TCPStream). Strips Telnet IAC sequences from the read path, injects IAC escaping on the write path, and populates its TerminalChannel from protocol negotiation.

### Responsibilities

| Concern | Where it lives |
|---------|---------------|
| IAC parsing state machine | TelnetStream.read() |
| Option negotiation (WILL/WONT/DO/DONT) | TelnetStream (private) |
| Subnegotiation (NAWS, TERMINAL_TYPE, CHARSET) | TelnetStream (private) |
| NVT commands (BRK, IP, EC, EL, AYT) | TelnetStream → TerminalChannel events |
| IAC byte escaping on write (0xFF → 0xFF 0xFF) | TelnetStream.write() |
| Inbound newline normalization (\r\n → \r, \r\0 → \r) | TelnetStream.read() |
| Terminal size | TelnetStream → TerminalChannel.width/height |
| Feature detection | TelnetStream → TerminalChannel.features |

### Collection Registration

TelnetStream is NOT a Collection-managed object. It's created dynamically by TelnetServer when a client connects, paired with the accepted TCPStream. Marked with `ObjectFlags.dynamic | ObjectFlags.temporary`.

### Initialization

On construction, TelnetStream sends the initial negotiation sequence:
```
IAC WILL ECHO
IAC DONT ECHO
IAC WILL SUPPRESS_GO_AHEAD
IAC DO TERMINAL_TYPE
IAC DO WINDOW_SIZE
IAC DO CHARSET
```

### Read Path

```d
override ptrdiff_t read(void[] buffer)
{
    // Read from inner stream
    ubyte[512] raw = void;
    auto n = _inner.read(raw[]);
    if (n <= 0)
        return n;

    // Parse IAC sequences, extract clean data
    size_t out_pos = 0;
    for (size_t i = 0; i < n; ++i)
    {
        if (raw[i] == 0xFF)  // IAC
        {
            // ... parse command, update state, set terminal_channel events ...
            // NVT commands → _terminal.pending_events
            // Subneg NAWS → _terminal.width/height + resized event
            // Option neg → update _server_state/_client_state
            continue;
        }
        // CRLF handling: \r\n → \n, \r\0 → \r, skip bare \0
        buffer[out_pos++] = raw[i];
    }
    return out_pos;
}
```

### Write Path

```d
override ptrdiff_t write(const(void[])[] data...)
{
    // Escape 0xFF bytes and translate \n → \r\n
    // Write escaped data to inner stream
}
```

## ConsoleStream

The platform's local terminal as a Stream. Handles raw mode setup, virtual key translation, terminal capability detection, and resize events. One per process, created in `main.d` for interactive mode only.

Not a generic I/O stream — specifically the console terminal. Reads from stdin via platform APIs (Windows `ReadConsoleInput`, POSIX `read(STDIN_FILENO)`), writes to stdout (Windows `WriteConsoleA`, POSIX `write(STDOUT_FILENO)`). Detects pipe vs real terminal and sets features accordingly.

## Line Submit Convention

**`\r` (CR, 0x0D) is the universal line-submit character.**

Every terminal sends `\r` when Enter is pressed. After stream normalization, Session always receives `\r` as the submit signal:

| Source | Raw Enter key | After stream normalization |
|--------|--------------|---------------------------|
| Serial (PuTTY) | `\r` | `\r` (passthrough) |
| Telnet NVT | `\r\n` (RFC 854) | `\r` (TelnetStream strips `\n`) |
| Windows console | `\r` (VK_RETURN) | `\r` (ConsoleStream passthrough) |
| POSIX raw terminal | `\r` (raw mode) | `\r` (ConsoleStream passthrough) |
| Piped input / scripts | `\n` | `\n` (no translation) |

Session treats both `\r` and `\n` as line-submit for compatibility. Bare `\n` comes from piped input (startup.conf, test harness, `echo "cmd" | telnet`). The `crlf` feature flag is NOT set for streams that already normalize — it only applies to raw streams where Session must handle `\r\n` pairs itself.

## TelnetServer Changes

Current flow:
```
TCPServer accepts → TelnetServer.acceptConnection(TCPStream) → createSession!TelnetSession(stream)
```

New flow:
```
TCPServer accepts → TelnetServer.acceptConnection(TCPStream)
    → create TelnetStream wrapping TCPStream
    → console.createSession(telnet_stream)   // plain Session
```

TelnetServer no longer needs to know about session internals. It creates the protocol stream and hands it to Console for a generic Session.

## main.d Changes

Current flow:
```d
active_session = allocT!ConsoleSession(g_app.console);
```

New flow:
```d
console_stream = allocT!ConsoleStream();
active_session = g_app.console.createSession(console_stream);
```

## Migration Path

### Phase 1: Add TerminalChannel to Stream base
- Define `TerminalChannel` struct and `TerminalEvents` enum
- Add `terminal_channel()` virtual to Stream (returns null)
- Zero impact on existing code

### Phase 2: Create TelnetStream
- Extract IAC parsing from TelnetSession into TelnetStream (~400 lines move)
- TelnetStream wraps TCPStream, populates its TerminalChannel
- TelnetServer creates TelnetStream + plain Session (instead of TelnetSession)
- Delete TelnetSession

### Phase 3: Unify echo into Session
- Merge the echo logic from TelnetSession and ConsoleSession into base Session
- Gate on `_features.escape` (already the pattern in both implementations)
- The two implementations are nearly identical — diff-based cursor repositioning

### Phase 4: Create ConsoleStream
- Extract Windows/POSIX terminal I/O from ConsoleSession into ConsoleStream (~300 lines move)
- main.d creates ConsoleStream + Session (instead of ConsoleSession)
- Delete ConsoleSession

### Phase 5: Merge SerialSession into Session
- SerialSession is already "Session + Stream" — its logic becomes the base Session behavior
- Delete SerialSession class

### Phase 6: Clean up
- Session.write_output() is no longer abstract — it writes to the stream
- StringSession may stay as a special case (no stream, buffer output) or use a MemoryStream
- SimpleSession may stay or become Session + write-only stream
- Remove dead code

## Line Ending Convention

**Rule:** Session writes `\r\n` for newlines. Streams are transparent byte pipes — no outbound translation.

This is correct for every transport:
- **Raw serial** — terminal emulators (PuTTY) expect `\r\n` for newline
- **Telnet** — NVT spec requires `\r\n`
- **ConsoleStream** — raw mode (both Windows and POSIX) needs explicit `\r\n`

**Inbound normalization** is the stream's job — different transports encode newlines differently on input:

| Stream | Inbound (read) | Outbound (write) |
|--------|----------------|-------------------|
| TelnetStream | `\r\n` → `\r`, `\r\0` → `\r`, strip NUL, escape 0xFF handling | Passthrough (Session sends `\r\n`). Escape 0xFF → 0xFF 0xFF. |
| ConsoleStream (Windows) | INPUT_RECORD → chars, Enter → `\r` | Passthrough |
| ConsoleStream (POSIX) | raw bytes, Enter → `\r` | Passthrough |
| Raw Stream (serial, TCP) | no translation | no translation |

Session receives `\r` as the line-submit character from all transports.

## Cursor Control — The Universal Language

ANSI escape sequences are the cursor control mechanism for all transports. There is no separate cursor protocol — Session emits ANSI sequences into the stream, and the terminal emulator on the far end interprets them. This works identically whether the backing transport is serial (PuTTY), Telnet, SSH, or a local console.

### What each layer does

| Layer | Responsibility |
|-------|---------------|
| **Session** | Emits ANSI sequences for cursor movement, line editing, progressive output |
| **Stream** | Passes ANSI sequences through transparently (they're just bytes). Only strips/adds its own protocol framing (IAC for Telnet, SSH channel framing, etc.) |
| **Terminal emulator** | Interprets ANSI sequences and renders them (PuTTY, xterm, Windows Terminal) |

### Feature gating

Session checks `ClientFeatures` from TerminalChannel before emitting sequences:

| Feature | Gates |
|---------|-------|
| `escape` | Any `\x1b[` sequence at all |
| `cursor` | Cursor movement (`\x1b[nA/B/C/D`, `\x1b[row;colH`) |
| `format` | Line/screen erase (`\x1b[2K`, `\x1b[2J`) |
| `textattrs` | Bold, underline, dim (`\x1b[1m`, `\x1b[4m`) |
| `basiccolour` | 16-color (`\x1b[31m`) |
| `fullcolour` | 256/24-bit color (`\x1b[38;2;R;G;Bm`) |

Terminals without `escape` support get plain text only — no cursor movement, no colors, no progressive output. This is the pipe/dumb-terminal fallback.

### How features get set per transport

| Transport | How features are determined |
|-----------|---------------------------|
| **TelnetStream** | Negotiated via TERMINAL_TYPE subneg → mapped to feature preset (xterm, vt100, etc.) |
| **ConsoleStream** | Auto-detected from platform (Windows console mode, POSIX terminfo) |
| **Raw serial** | No auto-detection possible. Configured externally via console command (e.g. `features=xterm`) or defaults to `vt100` |
| **SSHStream** | From SSH pty-req channel request (terminal type + modes) |

### Key ANSI sequences used

```
Cursor movement:
  \x1b[nA        — move up n lines
  \x1b[nB        — move down n lines
  \x1b[nC        — move right n columns
  \x1b[nD        — move left n columns
  \x1b[row;colH  — absolute position (1-based)
  \r             — carriage return (column 1, same line)

Cursor save/restore:
  \x1b[s         — save cursor position
  \x1b[u         — restore cursor position

Erase:
  \x1b[K         — erase from cursor to end of line
  \x1b[2K        — erase entire line
  \x1b[2J        — erase entire screen

Cursor visibility:
  \x1b[?25h      — show cursor
  \x1b[?25l      — hide cursor
```

## LiveViewState — Reusable Animated/Interactive Views

`LiveViewState` (`src/manager/console/live_view.d`) is an abstract `CommandState` that manages viewport, scrolling, input, and screen rendering. Commands subclass it and provide content; LiveViewState handles everything else.

### Subclass interface

```d
class LiveViewState : CommandState
{
    abstract uint content_height();                                  // total lines of content
    abstract void draw_content(uint offset, uint count, uint width); // render visible slice
    const(char)[] status_text() { return null; }                     // optional status bar
}
```

### Render modes

| Mode | Mechanism | On exit |
|------|-----------|---------|
| `fullscreen` | Alternate screen (`\x1b[?1049h`), absolute positioning | Content vanishes, normal screen restored |
| `inline_` | Cursor-up to rewrite region on normal screen | Last render stays in scrollback |
| `auto_` | Fullscreen if terminal has cursor support, dumb fallback otherwise |

### Built-in input handling

LiveViewState handles scrolling input for all subclasses:
- **Up/Down** — scroll one line
- **PgUp/PgDn** — scroll one page
- **Home** — jump to top, disable follow
- **End** — jump to bottom, re-enable follow
- **q / Ctrl+C** — exit view

### Follow mode

`_follow` flag (default true): when content grows, viewport auto-scrolls to the bottom. Pressing Up or Home disables follow. Pressing End re-enables it. Used by log tailing — scroll up to read history, press End to resume following.

### Dumb terminal fallback

When the terminal has no cursor support, LiveViewState reprints the full content every 2 seconds. Each reprint is separated by a blank line. Functional but not pretty.

### Subclass hierarchy

```
LiveViewState (abstract)
├── CollectionWatchState — live collection table (/interface/print --watch)
├── LogFollowState       — log tail with follow mode (/system/log follow)
├── TextViewState        — static text pager (less-like)
└── EditViewState        — text viewer/editor (nano-like)
        adds: cursor within content, insert/delete, save/discard
        viewer = editor with editing disabled
```

### Usage example

```d
// In any command's execute():
if (watch_flag)
    return allocator.allocT!CollectionWatchState(session, this, _collection);

// CollectionWatchState just provides content:
class CollectionWatchState : LiveViewState
{
    override uint content_height()
        => cast(uint)_collection.item_count + 1;

    override void draw_content(uint offset, uint count, uint width)
    {
        // Build Table, call table.render_viewport(session, offset, count)
    }

    override const(char)[] status_text()
        => tformat("{0} items", _collection.item_count);
}
```

### Inline mode for compact widgets

A small live chart or progress indicator uses `LiveViewMode.inline_`:
```d
return allocator.allocT!MyChartState(session, command, LiveViewMode.inline_);
```

The chart renders in-place on the normal screen. On exit (q/Ctrl+C), the last render stays visible in the terminal output — it doesn't vanish like fullscreen mode.

## Future Extensions

### SSHStream
Would wrap TCPStream, handle SSH protocol framing, key exchange, channel multiplexing. Populates TerminalChannel from SSH channel requests (window-change, pty-req). Session sees it identically to TelnetStream.

### WebSocketStream (console access)
HTTP upgrade → WebSocket framing. Terminal state negotiated via a JSON side-channel message. Same TerminalChannel interface to Session.

### Interlink Console
Remote console over the interlink protocol. Console commands forwarded between M0/D0 cores. Session backed by an InterlinkStream with terminal channel support.
