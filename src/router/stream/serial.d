module router.stream.serial;

import urt.array;
import urt.io;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.meta.nullable;
import urt.result;
import urt.string;
import urt.string.format;
import urt.time;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;
import manager.reactor;

import router.port;
public import router.stream;

version (Windows)
{
    import urt.internal.sys.windows;
    version = ReactorRx;
}
else version(Posix)
{
    import urt.internal.sys.posix;
    import urt.internal.sys.posix.termios;
    import urt.internal.stdc.errno : EAGAIN, EWOULDBLOCK, EINTR;
    version (linux)
        version = ReactorRx;
}
else version (Embedded)
{
    import urt.driver.uart;
}
else version (FreeStanding)
{
    static assert(false, "SerialStream: no UART driver for this FreeStanding target");
}
else
    static assert(false, "Unsupported platform!");

nothrow @nogc:


enum StopBits : ubyte
{
    one,
    one_point_five,
    two,
}

enum Parity : ubyte
{
    none,
    even,
    odd,
    mark,
    space
}

enum FlowControl : ubyte
{
    none,
    hardware,
    software,
    dsr_dtr,

    rts_cts = hardware,
    xon_xoff = software
}

struct ModemLines
{
    bool valid;         // port open and query succeeded
    bool outputs_valid; // rts/dtr are readable (posix only; windows can't read back outputs)
    bool rts, dtr;      // what we assert
    bool cts, dsr, dcd, ri; // what the peer presents
}

struct SerialParams
{
    this(int baud)
    {
        this.baud_rate = baud;
    }

    uint baud_rate = 9600;
    ubyte data_bits = 8;
    StopBits stop_bits = StopBits.one;
    Parity parity = Parity.none;
    FlowControl flow_control = FlowControl.none;
}

class SerialStream : Stream
{
    version (Embedded)
        alias Properties = AliasSeq!(Prop!("device", device),
                                     Prop!("baud-rate", baud_rate),
                                     Prop!("data-bits", data_bits),
                                     Prop!("parity", parity),
                                     Prop!("stop-bits", stop_bits),
                                     Prop!("flow-control", flow_control),
                                     Prop!("tx-gpio", tx_gpio),
                                     Prop!("rx-gpio", rx_gpio),
                                     Prop!("rts-gpio", rts_gpio),
                                     Prop!("cts-gpio", cts_gpio),
                                     Prop!("de-gpio", de_gpio));
    else
        alias Properties = AliasSeq!(Prop!("device", device),
                                     Prop!("baud-rate", baud_rate),
                                     Prop!("data-bits", data_bits),
                                     Prop!("parity", parity),
                                     Prop!("stop-bits", stop_bits),
                                     Prop!("flow-control", flow_control));
nothrow @nogc:

    enum type_name = "serial";
    enum path = "/stream/serial";

    this(CID id, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!SerialStream, id, flags, options);
    }

    // Properties...

    final String device() const pure
        => _device;
    final StringResult device(String value)
    {
        if (!value)
            return StringResult("device cannot be empty");
        if (_device == value)
            return StringResult.success;
        version (Embedded)
        {
            if (value.length == 5 && value[][0 .. 4] == "uart")
            {
                uint port = value[][4] - '0';
                if (port < num_uarts)
                {
                    _uart_port = cast(byte)port;
                    _device = value.move;
                    mark_set!(typeof(this), "device");
                    restart();
                    return StringResult.success;
                }
            }
            _device = String();
            return StringResult("invalid device: expected uart0-uart" ~ cast(char)('0' + num_uarts - 1));
        }
        else
        {
            _device = value.move;
            mark_set!(typeof(this), "device");
            restart();
            return StringResult.success;
        }
    }

    final uint baud_rate() const pure
        => _params.baud_rate;
    final StringResult baud_rate(uint value)
    {
        if (value == 0)
            return StringResult("baud rate must be greater than 0");
        if (_params.baud_rate == value)
            return StringResult.success;
        _params.baud_rate = value;
        mark_set!(typeof(this), "baud-rate");
        restart();
        return StringResult.success;
    }

    uint data_bits() const pure
        => _params.data_bits;
    StringResult data_bits(uint value)
    {
        version (Embedded)
            enum uint max_data_bits = 9;
        else
            enum uint max_data_bits = 8;
        if (value < 5 || value > max_data_bits)
            return StringResult(max_data_bits == 9 ? "data bits must be between 5 and 9" : "data bits must be between 5 and 8");
        if (_params.data_bits == cast(ubyte)value)
            return StringResult.success;
        _params.data_bits = cast(ubyte)value;
        mark_set!(typeof(this), "data-bits");
        restart();
        return StringResult.success;
    }

    Parity parity() const pure
        => _params.parity;
    const(char)[] parity(Parity value)
    {
        version (Embedded)
        {
            if (value > Parity.odd)
                return "UART only supports none, even, or odd parity";
        }
        if (_params.parity == value)
            return null;
        _params.parity = value;
        mark_set!(typeof(this), "parity");
        restart();
        return null;
    }

    StopBits stop_bits() const pure
        => _params.stop_bits;
    void stop_bits(StopBits value)
    {
        if (_params.stop_bits == value)
            return;
        _params.stop_bits = value;
        mark_set!(typeof(this), "stop-bits");
        restart();
    }

    FlowControl flow_control() const pure
        => _params.flow_control;
    void flow_control(FlowControl value)
    {
        if (_params.flow_control == value)
            return;
        _params.flow_control = value;
        mark_set!(typeof(this), "flow-control");
        restart();
    }

    version (Embedded)
    {
        final byte tx_gpio() const pure
            => _tx_gpio;
        final void tx_gpio(byte value)
        {
            _tx_gpio = value;
            mark_set!(typeof(this), "tx-gpio");
            restart();
        }

        final byte rx_gpio() const pure
            => _rx_gpio;
        final void rx_gpio(byte value)
        {
            _rx_gpio = value;
            mark_set!(typeof(this), "rx-gpio");
            restart();
        }

        final byte rts_gpio() const pure
            => _rts_gpio;
        final void rts_gpio(byte value)
        {
            _rts_gpio = value;
            mark_set!(typeof(this), "rts-gpio");
            restart();
        }

        final byte cts_gpio() const pure
            => _cts_gpio;
        final void cts_gpio(byte value)
        {
            _cts_gpio = value;
            mark_set!(typeof(this), "cts-gpio");
            restart();
        }

        final byte de_gpio() const pure
            => _de_gpio;
        final void de_gpio(byte value)
        {
            _de_gpio = value;
            mark_set!(typeof(this), "de-gpio");
            restart();
        }
    }

    // API...

    final override bool validate() const
        => !_device.empty;

    override CompletionStatus startup()
    {
        version(Windows)
        {
            _h_com = CreateFile(_device[].twstringz, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null);
            if (_h_com == INVALID_HANDLE_VALUE)
                return CompletionStatus.error;

            if (!configure_port(true))
                return fail_windows_startup();

            // manual-reset event for the main thread's synchronous overlapped writes
            _write_ev = CreateEvent(null, true, false, null);
            if (_write_ev is null)
                return fail_windows_startup();
        }
        else version(Posix)
        {
            _fd = urt.internal.sys.posix.open(device[].tstringz, O_RDWR | O_NOCTTY | O_NDELAY);
            if (_fd == -1)
            {
                log.error("failed to open device ", this.device);
                return CompletionStatus.error;
            }

            if (!configure_port(true))
                return fail_posix_startup();
        }
        else version (Embedded)
        {
            static import bm = urt.driver.uart;
            __gshared immutable bm.StopBits[3] stop_bits_map = [ bm.StopBits.one, bm.StopBits.one_point_five, bm.StopBits.two ];
            __gshared immutable bm.Parity[5] parity_map = [ bm.Parity.none, bm.Parity.even, bm.Parity.odd, bm.Parity.none, bm.Parity.none ];

            bm.UartConfig cfg;
            cfg.baud_rate = _params.baud_rate;
            cfg.data_bits = _params.data_bits;
            cfg.stop_bits = stop_bits_map[_params.stop_bits];
            cfg.parity = parity_map[_params.parity];
            if (_tx_gpio >= 0)
                cfg.tx_gpio = cast(ubyte)_tx_gpio;
            if (_rx_gpio >= 0)
                cfg.rx_gpio = cast(ubyte)_rx_gpio;
            if (_rts_gpio >= 0)
                cfg.rts_gpio = cast(ubyte)_rts_gpio;
            if (_cts_gpio >= 0)
                cfg.cts_gpio = cast(ubyte)_cts_gpio;
            if (_de_gpio >= 0)
            {
                cfg.rs485.enabled = true;
                cfg.rs485.de_gpio = cast(ubyte)_de_gpio;
            }

            if (!uart_open(_uart, cast(ubyte)_uart_port, cfg))
                return CompletionStatus.error;
        }

        version (ReactorRx)
        {
            version (Windows)
                OsFile os_file = _h_com;
            else
                OsFile os_file = _fd;
            if (!g_app.watch_io(os_file, &deliver_rx, &io_error))
            {
                // don't run with a port nobody drains
                log.error("failed to register serial port with the reactor");
                version (Windows)
                    return fail_windows_startup();
                else
                {
                    urt.internal.sys.posix.close(_fd);
                    _fd = -1;
                    return CompletionStatus.error;
                }
            }
        }

        return CompletionStatus.complete;
    }

    // Applies framing, baud, flow control and modem-line state to the open port. Called at startup,
    // and again in place when flow-control is reconfigured at runtime (buffers preserved, no reopen).
    version (Embedded) {} else
    private bool configure_port(bool flush_buffers)
    {
        version(Windows)
        {
            if (_h_com == INVALID_HANDLE_VALUE)
                return false;

            DCB dcb = void;
            ZeroMemory(&dcb, DCB.sizeof);
            dcb.DCBlength = DCB.sizeof;
            if (!GetCommState(_h_com, &dcb))
                return false;

            dcb._bf = 1;

            dcb.BaudRate = DWORD(_params.baud_rate);
            dcb.ByteSize = _params.data_bits;

            if (_params.stop_bits == StopBits.one)
                dcb.StopBits = ONESTOPBIT;
            else if (_params.stop_bits == StopBits.one_point_five)
                dcb.StopBits = ONE5STOPBITS;
            else if (_params.stop_bits == StopBits.two)
                dcb.StopBits = TWOSTOPBITS;

            switch (_params.parity)
            {
                case Parity.none:   dcb.Parity = NOPARITY;      break;
                case Parity.even:   dcb.Parity = EVENPARITY;    break;
                case Parity.odd:    dcb.Parity = ODDPARITY;     break;
                case Parity.mark:   dcb.Parity = MARKPARITY;    break;
                case Parity.space:  dcb.Parity = SPACEPARITY;   break;
                default: assert(false);
            }
            if (_params.parity != Parity.none)
                dcb._bf |= 2; // fParity: set to enable parity checking?

            // RTS idles asserted ("host ready") in the non-hardware modes: we always have receive
            // buffer, and peers that honor RTS/CTS (Silabs NCPs) stop transmitting if it idles low
            switch (_params.flow_control)
            {
                case FlowControl.none:
                    dcb._bf &= ~4; // fOutxCtsFlow
                    dcb._bf &= ~8; // fOutxDsrFlow
                    dcb._bf &= ~0x40; // fDsrSensitivity
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.enable << 12; // fRtsControl
                    dcb._bf |= DTRControl.disable << 4; // fDtrControl
                    break;
                case FlowControl.hardware:
                    dcb._bf |= 4; // fOutxCtsFlow
                    dcb._bf &= ~8; // fOutxDsrFlow
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.handshake << 12; // fRtsControl
                    dcb._bf |= DTRControl.enable << 4; // fDtrControl
                    break;
                case FlowControl.software:
                    dcb._bf &= ~4; // fOutxCtsFlow
                    dcb._bf &= ~8; // fOutxDsrFlow
                    dcb._bf &= ~0x40; // fDsrSensitivity
                    dcb._bf |= 0x100; // fOutX
                    dcb._bf |= 0x200; // fInX
                    dcb.XonChar = 0x11;
                    dcb.XoffChar = 0x13;
                    dcb.XonLim = 200;
                    dcb.XoffLim = 200;
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.enable << 12; // fRtsControl
                    dcb._bf |= DTRControl.enable << 4; // fDtrControl
                    break;
                case FlowControl.dsr_dtr:
                    dcb._bf &= ~4; // fOutxCtsFlow
                    dcb._bf |= 8; // fOutxDsrFlow
                    dcb._bf |= 0x40; // fDsrSensitivity
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.disable << 12; // fRtsControl
                    dcb._bf |= DTRControl.handshake << 4; // fDtrControl
                    break;
                default:
                    assert(false);
            }

            if (!SetCommState(_h_com, &dcb))
                return false;

            COMMTIMEOUTS timeouts = {};
            // The reactor parks one overlapped read per port. MAXDWORD interval+multiplier with a
            // bounded constant is the documented "complete on the first available byte(s)" mode;
            // the 1s constant is an idle tick so the op never pends unbounded.
            timeouts.ReadIntervalTimeout = -1;
            timeouts.ReadTotalTimeoutMultiplier = -1;
            timeouts.ReadTotalTimeoutConstant = 1000;
            // A synchronous WriteFile with no write timeout blocks forever when hardware flow control
            // gates output on CTS and the peer deasserts it - a whole-loop lockup. Bound it so WriteFile
            // returns a short count instead (fed to the same partial-write recovery as the Posix path).
            // Multiplier scales with size so a legitimately slow/large write at low baud never trips it.
            timeouts.WriteTotalTimeoutConstant = 100;
            timeouts.WriteTotalTimeoutMultiplier = 2;
            if (!SetCommTimeouts(_h_com, &timeouts))
                return false;

            if (flush_buffers)
                PurgeComm(_h_com, PURGE_TXCLEAR | PURGE_RXCLEAR);
            return true;
        }
        else version(Posix)
        {
            if (_fd == -1)
                return false;

            termios tty;
            if (tcgetattr(_fd, &tty) != 0)
                return false;

            // on Linux the baud is set after tcsetattr via termios2/BOTHER (set_linux_custom_baud)
            version (linux) {}
            else
            {
                // other Posix: standard rates only, via the classic cfsetospeed/Bxxx path.
                speed_t speed;
                if (!posix_baud(_params.baud_rate, speed))
                {
                    log.error("unsupported serial baud rate ", _params.baud_rate);
                    return false;
                }
                if (cfsetospeed(&tty, speed) != 0 || cfsetispeed(&tty, speed) != 0)
                    return false;
            }

            tty.c_cflag &= ~(PARENB | PARODD | CMSPAR);
            final switch (_params.parity)
            {
                case Parity.none:
                    break;
                case Parity.even:
                    tty.c_cflag |= PARENB;
                    break;
                case Parity.odd:
                    tty.c_cflag |= PARENB | PARODD;
                    break;
                case Parity.mark:
                    tty.c_cflag |= PARENB | PARODD | CMSPAR;
                    break;
                case Parity.space:
                    tty.c_cflag |= PARENB | CMSPAR;
                    break;
            }

            tty.c_cflag &= ~CSTOPB;
            if (_params.stop_bits == StopBits.two)
                tty.c_cflag |= CSTOPB;
            else if (_params.stop_bits == StopBits.one_point_five)
            {
                log.error("1.5 stop bits are not supported on Posix");
                return false;
            }

            tty.c_cflag &= ~CSIZE;
            switch (_params.data_bits)
            {
                case 5: tty.c_cflag |= CS5; break;
                case 6: tty.c_cflag |= CS6; break;
                case 7: tty.c_cflag |= CS7; break;
                case 8: tty.c_cflag |= CS8; break;
                default:
                    log.error("unsupported data bits: ", _params.data_bits);
                    return false;
            }

            tty.c_cflag &= ~CRTSCTS;
            tty.c_cflag |= CREAD | CLOCAL;
            tty.c_iflag &= ~(IXON | IXOFF | IXANY);
            final switch (_params.flow_control)
            {
                case FlowControl.none:
                    break;
                case FlowControl.hardware:
                    tty.c_cflag |= CRTSCTS;
                    break;
                case FlowControl.software:
                    tty.c_iflag |= IXON | IXOFF;
                    break;
                case FlowControl.dsr_dtr:
                    log.error("DSR/DTR flow control is not supported on Posix");
                    return false;
            }

            tty.c_lflag &= ~ICANON;
            tty.c_lflag &= ~ECHO;   // Disable echo
            tty.c_lflag &= ~ECHOE;  // Disable erasure
            tty.c_lflag &= ~ECHONL; // Disable new-line echo
            tty.c_lflag &= ~ISIG;   // Disable interpretation of INTR, QUIT and SUSP
            tty.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL); // Disable any special handling of received bytes

            tty.c_oflag &= ~OPOST; // Prevent special interpretation of output bytes (e.g. newline chars)
            tty.c_oflag &= ~ONLCR; // Prevent conversion of newline to carriage return/line feed

            tty.c_cc[VTIME] = 0;
            tty.c_cc[VMIN] = 0;

            if (tcsetattr(_fd, TCSANOW, &tty) != 0)
                return false;
            version (linux)
            {
                if (!set_linux_custom_baud(_fd, _params.baud_rate))
                {
                    log.error("failed to set baud rate ", _params.baud_rate);
                    return false;
                }
            }

            // RTS idles asserted ("host ready") in the non-hardware modes: we always have receive
            // buffer, and peers that honor RTS/CTS (Silabs NCPs) stop transmitting if it idles low
            int dtr_bit = TIOCM_DTR, rts_bit = TIOCM_RTS;
            final switch (_params.flow_control)
            {
                case FlowControl.none:
                    ioctl(_fd, TIOCMBIC, &dtr_bit);
                    ioctl(_fd, TIOCMBIS, &rts_bit);
                    break;
                case FlowControl.hardware:
                    ioctl(_fd, TIOCMBIS, &dtr_bit);     // RTS is owned by CRTSCTS
                    break;
                case FlowControl.software:
                    ioctl(_fd, TIOCMBIS, &dtr_bit);
                    ioctl(_fd, TIOCMBIS, &rts_bit);
                    break;
                case FlowControl.dsr_dtr:
                    break;                              // unreachable: rejected earlier
            }

            if (flush_buffers)
                tcflush(_fd, TCIOFLUSH);
            return true;
        }
    }

    override CompletionStatus shutdown()
    {
        version (Windows)
        {
            if (_h_com != INVALID_HANDLE_VALUE)
            {
                g_app.unwatch_io(_h_com);
                // discard buffered tx before closing: a close that tries to drain output the
                // peer's flow control will never accept can block in the driver
                PurgeComm(_h_com, PURGE_TXABORT | PURGE_RXABORT | PURGE_TXCLEAR | PURGE_RXCLEAR);
                CloseHandle(_h_com);
                _h_com = INVALID_HANDLE_VALUE;
            }
            if (_write_ev !is null)
            {
                CloseHandle(_write_ev);
                _write_ev = null;
            }
        }
        else version (Posix)
        {
            if (_fd != -1)
            {
                version (linux)
                    g_app.unwatch_io(_fd);
                tcflush(_fd, TCIOFLUSH); // discard un-drainable output so close() can't block
                urt.internal.sys.posix.close(_fd);
                _fd = -1;
            }
        }
        else version (Embedded)
        {
            uart_close(_uart);
        }
        return CompletionStatus.complete;
    }


    override void update()
    {
        version (ReactorRx)
        {
            // rx and read errors are delivered by the reactor via incoming()/restart()
        }
        else version (Posix)
        {
            poll_os_rx();
        }
        else version (Embedded)
        {
            uart_poll(_uart);
            if (uart_check_errors(_uart) != UartError.none)
                restart();
            else
                poll_os_rx();
        }

        super.update();
    }

    // On linux and windows the reactor delivers rx via incoming(); every other
    // platform drains the device here in update() and pushes the same way.
    // Both routes converge on the base Stream _rx_buffer / rx_handler, so read()
    // and pending() use the base (buffer-backed) implementations.
    version (ReactorRx) {} else
    private void poll_os_rx()
    {
        MonoTime now = getTime();
        ubyte[512] buf = void;
        while (true)
        {
            version(Posix)
            {
                ssize_t n = urt.internal.sys.posix.read(_fd, buf.ptr, buf.length);
                if (n < 0)
                {
                    if (is_transient_errno())
                        return;
                    restart();
                    return;
                }
                if (n == 0)
                    return;
            }
            else version (Embedded)
            {
                ptrdiff_t n = uart_read(_uart, buf[]);
                if (n <= 0)
                    return;
            }
            incoming(buf[0 .. n], now);
        }
    }

    version (ReactorRx)
    {
        private void deliver_rx(const(void)[] data, MonoTime rx_time)
        {
            incoming(data, rx_time);
        }

        private void io_error()
        {
            restart();
        }
    }

    override ptrdiff_t write(const(void[])[] data...)
    {
        ptrdiff_t bytes_written;
        version(Windows)
        {
            import urt.array;

            // Windows has no gather WriteFile for serial; we need to gather manually! :(
            const(void)[] send_buffer;
            void[] gather_buffer;
            Array!ubyte big_buffer; // TODO: use Array!(ubyte, 1024) !!
            ubyte[1024] stack_buffer = void;
            if (data.length > 1)
            {
                size_t total_length = 0;
                foreach (d; data)
                    total_length += d.length;
                if (total_length > stack_buffer.length)
                    gather_buffer = big_buffer.extend(total_length);
                else
                    gather_buffer = stack_buffer[0 .. total_length];
                size_t offset = 0;
                foreach (d; data)
                {
                    gather_buffer[offset .. offset + d.length] = d;
                    offset += d.length;
                }
                send_buffer = gather_buffer;
            }
            else
                send_buffer = data[0];

            // Overlapped handle, so the write must be overlapped too; the set low bit on hEvent
            // keeps the completion off the reactor's completion port (the kernel ignores a
            // handle's low tag bits). GetOverlappedResult blocks until the write completes or the
            // comm write timeout expires with a short count, same as the old synchronous path.
            DWORD _bytes_written;
            OVERLAPPED ov;
            ov.hEvent = cast(HANDLE)(cast(size_t)_write_ev | 1);
            if (!WriteFile(_h_com, send_buffer.ptr, cast(DWORD)send_buffer.length, null, &ov) &&
                GetLastError() != ERROR_IO_PENDING)
            {
                restart();
                return -1;
            }
            if (!GetOverlappedResult(_h_com, &ov, &_bytes_written, true) &&
                GetLastError() != ERROR_SEM_TIMEOUT)   // comm write timeout: a short count, not an error
            {
                restart();
                return -1;
            }

            bytes_written = _bytes_written;
            if (_logging || has_tap)
                write_to_log(false, send_buffer[0 .. bytes_written]);
        }
        else version(Posix)
        {
            foreach (d; data)
            {
                const(ubyte)[] buf = cast(const(ubyte)[])d;
                while (buf.length)
                {
                    ssize_t n = urt.internal.sys.posix.write(_fd, buf.ptr, buf.length);
                    if (n < 0)
                    {
                        if (is_transient_errno())
                            goto posix_write_done;
                        restart();
                        return bytes_written > 0 ? bytes_written : -1;
                    }
                    if (n == 0)
                        goto posix_write_done;
                    bytes_written += n;
                    if (_logging || has_tap)
                        write_to_log(false, buf[0 .. n]);
                    buf = buf[n .. $];
                }
            }
        posix_write_done:
        }
        else version (Embedded)
        {
            bytes_written = uart_writev(_uart, data);
            if ((_logging || has_tap) && bytes_written > 0)
            {
                import urt.util : min;
                size_t remain = bytes_written;
                for (size_t i = 0; remain > 0; ++i)
                {
                    size_t len = min(data[i].length, remain);
                    write_to_log(false, data[i][0 .. len]);
                    remain -= len;
                }
            }
        }
        if (bytes_written > 0)
            add_tx_bytes(bytes_written);
        return bytes_written;
    }

    override ptrdiff_t flush()
    {
        version (Windows)
        {
            PurgeComm(_h_com, PURGE_RXABORT | PURGE_RXCLEAR);
            return 0;
        }
        else version (Posix)
        {
            tcflush(_fd, TCIFLUSH);
            return 0;
        }
        else version (Embedded)
        {
            uart_tx_flush(_uart);
            return 0;
        }
    }

    // Manually drive the modem control lines. Only meaningful when flow-control doesn't own the
    // line; gives callers hardware reset agency over devices with reset wired to RTS/DTR
    // (e.g. Silabs radio dongles, which some boots leave held in reset).
    final bool set_rts(bool asserted)
    {
        // RTS is owned by the UART under hardware (RTS/CTS) flow control; refuse rather than fight it
        assert(_params.flow_control != FlowControl.hardware, "cannot drive RTS manually while hardware flow control owns it");
        if (_params.flow_control == FlowControl.hardware)
            return false;
        version (Windows)
            return _h_com != INVALID_HANDLE_VALUE && EscapeCommFunction(_h_com, asserted ? SETRTS : CLRRTS) != 0;
        else version (Posix)
        {
            if (_fd == -1)
                return false;
            int bit = TIOCM_RTS;
            return ioctl(_fd, asserted ? TIOCMBIS : TIOCMBIC, &bit) == 0;
        }
        else
            return false;
    }

    final bool set_dtr(bool asserted)
    {
        // DTR is owned by the UART under DSR/DTR flow control
        assert(_params.flow_control != FlowControl.dsr_dtr, "cannot drive DTR manually while DSR/DTR flow control owns it");
        if (_params.flow_control == FlowControl.dsr_dtr)
            return false;
        version (Windows)
            return _h_com != INVALID_HANDLE_VALUE && EscapeCommFunction(_h_com, asserted ? SETDTR : CLRDTR) != 0;
        else version (Posix)
        {
            if (_fd == -1)
                return false;
            int bit = TIOCM_DTR;
            return ioctl(_fd, asserted ? TIOCMBIS : TIOCMBIC, &bit) == 0;
        }
        else
            return false;
    }

    // Live modem-line state: what we assert (RTS/DTR) and what the peer presents (CTS/DSR/DCD/RI).
    // Windows can only read the input lines; outputs_valid is false there.
    final ModemLines modem_lines()
    {
        ModemLines l;
        version (Windows)
        {
            if (_h_com == INVALID_HANDLE_VALUE)
                return l;
            DWORD status;
            if (!GetCommModemStatus(_h_com, &status))
                return l;
            l.valid = true;
            l.cts = (status & 0x10) != 0;   // MS_CTS_ON
            l.dsr = (status & 0x20) != 0;   // MS_DSR_ON
            l.ri  = (status & 0x40) != 0;   // MS_RING_ON
            l.dcd = (status & 0x80) != 0;   // MS_RLSD_ON
        }
        else version (Posix)
        {
            if (_fd == -1)
                return l;
            int bits;
            if (ioctl(_fd, TIOCMGET, &bits) != 0)
                return l;
            l.valid = true;
            l.outputs_valid = true;
            l.rts = (bits & TIOCM_RTS) != 0;
            l.dtr = (bits & TIOCM_DTR) != 0;
            l.cts = (bits & TIOCM_CTS) != 0;
            l.dsr = (bits & TIOCM_DSR) != 0;
            l.dcd = (bits & TIOCM_CAR) != 0;
            l.ri  = (bits & TIOCM_RNG) != 0;
        }
        return l;
    }

    version (linux)
    {
        // kernel line-event counters (CTS transitions, overruns, ...); false if the driver
        // doesn't implement TIOCGICOUNT (varies by usb-serial driver)
        final bool line_counters(out serial_icounter_struct counters)
            => _fd != -1 && ioctl(_fd, TIOCGICOUNT, &counters) == 0;
    }

private:
    version (Windows)
    {
        HANDLE _h_com = INVALID_HANDLE_VALUE;
        HANDLE _write_ev;
    }
    else version (Posix)
        int _fd = -1;
    else version (Embedded)
    {
        Uart _uart;
        byte _uart_port = -1;
    }

    String _device;
    SerialParams _params;
    version (Embedded)
    {
        byte _tx_gpio = -1;
        byte _rx_gpio = -1;
        byte _rts_gpio = -1;
        byte _cts_gpio = -1;
        byte _de_gpio = -1;
    }

    version (Windows)
    {
        CompletionStatus fail_windows_startup()
        {
            if (_h_com != INVALID_HANDLE_VALUE)
            {
                CloseHandle(_h_com);
                _h_com = INVALID_HANDLE_VALUE;
            }
            if (_write_ev !is null)
            {
                CloseHandle(_write_ev);
                _write_ev = null;
            }
            return CompletionStatus.error;
        }
    }
    else version (Posix)
    {
        CompletionStatus fail_posix_startup()
        {
            if (_fd != -1)
            {
                urt.internal.sys.posix.close(_fd);
                _fd = -1;
            }
            return CompletionStatus.error;
        }
    }
}


class SerialStreamModule : Module
{
    mixin DeclareModule!"stream.serial";
nothrow @nogc:

    override void pre_init()
    {
        version (Posix)
        {
            sync_serial_ports();
            _last_port_sync = getSysTime();
        }
    }

    override void init()
    {
        g_app.register_enum!StopBits();
        g_app.register_enum!Parity();
        g_app.register_enum!FlowControl();

        g_app.console.register_collection!SerialStream();
        g_app.console.register_command!serial_lines("/stream/serial", this, "lines");
        version (Posix)
            g_app.console.register_command!serial_devices("/stream/serial", this, "devices");
    }

    // /stream/serial/lines <name> - live modem-line state (and kernel line-event counters where the
    // driver supports them); the observability layer for flow-control experiments.
    void serial_lines(Session session, const(char)[] name)
    {
        SerialStream s = Collection!SerialStream().get(name);
        if (!s)
        {
            session.write_line(tconcat("no such serial stream: ", name));
            return;
        }

        ModemLines l = s.modem_lines();
        if (!l.valid)
        {
            session.write_line(tconcat("'", name, "': port not open or line query unsupported"));
            return;
        }

        if (l.outputs_valid)
            session.write_line(tconcat("'", name, "': RTS=", cast(int)l.rts, " DTR=", cast(int)l.dtr,
                                       "  <-  CTS=", cast(int)l.cts, " DSR=", cast(int)l.dsr, " DCD=", cast(int)l.dcd, " RI=", cast(int)l.ri));
        else
            session.write_line(tconcat("'", name, "': CTS=", cast(int)l.cts, " DSR=", cast(int)l.dsr,
                                       " DCD=", cast(int)l.dcd, " RI=", cast(int)l.ri, " (outputs not readable on this platform)"));

        version (linux)
        {
            serial_icounter_struct c;
            if (s.line_counters(c))
                session.write_line(tconcat("counters: cts=", c.cts, " dsr=", c.dsr, " rx=", c.rx, " tx=", c.tx,
                                           " frame=", c.frame, " overrun=", c.overrun, " parity=", c.parity,
                                           " brk=", c.brk, " buf_overrun=", c.buf_overrun));
            else
                session.write_line("counters: not supported by driver");
        }
    }

    override void update()
    {
        version (Posix)
        {
            SysTime now = getSysTime();
            if (now - _last_port_sync < 2.seconds)
                return;
            sync_serial_ports();
            _last_port_sync = now;
        }
    }

private:
    version (Posix)
        SysTime _last_port_sync;
}


private:

version(Windows)
{
    enum RTSControl : ubyte
    {
        disable, enable, handshake, toggle
    }
    enum DTRControl : ubyte
    {
        disable, enable, handshake
    }
}

version(Posix)
{
    struct iovec
    {
        void*   iov_base;
        size_t  iov_len;
    }

    enum FIONREAD = 0x541B;
    enum TIOCMGET = 0x5415;     // read the modem control/status bits
    enum TIOCMBIS = 0x5416;     // set the indicated modem control bits
    enum TIOCMBIC = 0x5417;     // clear the indicated modem control bits
    enum TIOCM_DTR = 0x002;
    enum TIOCM_RTS = 0x004;
    enum TIOCM_CTS = 0x020;
    enum TIOCM_CAR = 0x040;
    enum TIOCM_RNG = 0x080;
    enum TIOCM_DSR = 0x100;

    version (linux)
    {
        enum TIOCGICOUNT = 0x545D;  // kernel line-event counters; not all usb-serial drivers support it
        struct serial_icounter_struct
        {
            int cts, dsr, rng, dcd;
            int rx, tx;
            int frame, overrun, parity, brk;
            int buf_overrun;
            int[9] reserved;
        }
    }

    extern(C) ssize_t writev(int fd, const iovec* iov, int iovcnt);
    version (D_LP64)
        alias c_ulong = ulong;
    else
        alias c_ulong = uint;
    extern(C) int ioctl(int fd, c_ulong request, ...);

    bool is_transient_errno()
    {
        uint e = errno_result().system_code;
        return e == EAGAIN || e == EWOULDBLOCK || e == EINTR;
    }

    version (linux)
    bool set_linux_custom_baud(int fd, uint baud)
    {
        termios2 tty;
        if (ioctl(fd, TCGETS2, &tty) < 0)
            return false;

        tty.c_cflag &= ~CBAUD;
        tty.c_cflag |= BOTHER;
        tty.c_ispeed = baud;
        tty.c_ospeed = baud;
        return ioctl(fd, TCSETS2, &tty) == 0;
    }

    bool posix_baud(uint baud, out speed_t speed)
    {
        switch (baud)
        {
            case 0:       speed = B0;       return true;
            case 50:      speed = B50;      return true;
            case 75:      speed = B75;      return true;
            case 110:     speed = B110;     return true;
            case 134:     speed = B134;     return true;
            case 150:     speed = B150;     return true;
            case 200:     speed = B200;     return true;
            case 300:     speed = B300;     return true;
            case 600:     speed = B600;     return true;
            case 1200:    speed = B1200;    return true;
            case 1800:    speed = B1800;    return true;
            case 2400:    speed = B2400;    return true;
            case 4800:    speed = B4800;    return true;
            case 9600:    speed = B9600;    return true;
            case 19200:   speed = B19200;   return true;
            case 38400:   speed = B38400;   return true;
            case 57600:   speed = B57600;   return true;
            case 115200:  speed = B115200;  return true;
            case 230400:  speed = B230400;  return true;
            case 460800:  speed = B460800;  return true;
            case 500000:  speed = B500000;  return true;
            case 576000:  speed = B576000;  return true;
            case 921600:  speed = B921600;  return true;
            case 1000000: speed = B1000000; return true;
            case 1152000: speed = B1152000; return true;
            case 1500000: speed = B1500000; return true;
            case 2000000: speed = B2000000; return true;
            case 2500000: speed = B2500000; return true;
            case 3000000: speed = B3000000; return true;
            case 3500000: speed = B3500000; return true;
            case 4000000: speed = B4000000; return true;
            default:      return false;
        }
    }

    void serial_devices(Session session)
    {
        uint count;
        count += list_serial_dir(session, "/dev/serial/by-id", null);
        count += list_serial_ttys(session);
        if (count == 0)
            session.write_line("No serial devices found");
    }

    void sync_serial_ports()
    {
        // One port per kernel node (/dev/ttyUSB0 etc.). USB devices also appear under
        // /dev/serial/by-id, but that's just a symlink to the same node, so we don't
        // list it; we read the USB identity straight from sysfs instead.
        Array!String seen;
        scan_serial_ttys((const(char)[] name, const(char)[] path) nothrow @nogc {
            char[64] desc = void;
            char[64] manuf = void;
            char[96] product = void;
            char[64] serial = void;
            PortUsb usb = read_usb_ident(name, manuf[], product[], serial[]);
            publish_serial_port(seen, name, path, read_tty_driver_name(name, desc[]), serial_port_flags(name), usb);
        });

        Array!String gone;
        foreach (ref p; port_list())
        {
            if (p.kind != PortKind.serial || p.driver[] != SerialStreamModule.ModuleName)
                continue;

            bool still_there;
            foreach (ref id; seen[])
            {
                if (p.id[] == id[])
                {
                    still_there = true;
                    break;
                }
            }
            if (!still_there)
                gone ~= p.id[].makeString(defaultAllocator);
        }
        foreach (ref id; gone[])
            port_remove(PortKind.serial, id[]);
    }

    uint list_serial_ttys(Session session)
    {
        uint count = 0;
        scan_serial_ttys((const(char)[], const(char)[] path) nothrow @nogc {
            session.write_line(path);
            ++count;
        });
        return count;
    }

    uint list_serial_dir(Session session, const(char)[] dir, const(char)[] prefix)
    {
        uint count = 0;
        scan_serial_dir(dir, prefix, (const(char)[], const(char)[] path) nothrow @nogc {
            session.write_line(path);
            ++count;
        });
        return count;
    }

    void scan_serial_ttys(scope void delegate(const(char)[] name, const(char)[] path) nothrow @nogc visitor)
    {
        walk_dir("/sys/class/tty", (const(char)[] name) nothrow @nogc {
            if (!is_serial_tty(name))
                return;
            char[320] path = void;
            size_t n = make_path(path[], "/dev/", name);
            if (n)
                visitor(name, path[0 .. n]);
        });
    }

    void scan_serial_dir(const(char)[] dir, const(char)[] prefix,
                         scope void delegate(const(char)[] name, const(char)[] path) nothrow @nogc visitor)
    {
        walk_dir(dir, (const(char)[] name) nothrow @nogc {
            if (prefix && !name.startsWith(prefix))
                return;
            char[512] path = void;
            size_t n = make_path(path[], dir, "/", name);
            if (n)
                visitor(name, path[0 .. n]);
        });
    }

    void publish_serial_port(ref Array!String seen, const(char)[] name, const(char)[] path,
                             const(char)[] description, PortFlags flags, PortUsb usb = PortUsb.init)
    {
        auto id = tconcat("linux:serial:", path);
        port_add(PortKind.serial, id, name, path, SerialStreamModule.ModuleName, description, flags, usb);
        seen ~= id.makeString(defaultAllocator);
    }

    PortFlags serial_port_flags(const(char)[] name) pure
    {
        if (name.startsWith("ttyUSB") || name.startsWith("ttyACM") || name.startsWith("rfcomm"))
            return PortFlags.removable;
        return PortFlags.none;
    }

    bool is_serial_tty(const(char)[] name)
    {
        if (name.startsWith("ttyUSB") || name.startsWith("ttyACM") ||
            name.startsWith("ttyAMA") || name.startsWith("ttyS") ||
            name.startsWith("ttyTHS") || name.startsWith("rfcomm"))
            return true;

        char[320] path = void;
        size_t n = make_path(path[], "/sys/class/tty/", name, "/device");
        return n != 0 && access(path.ptr, F_OK) == 0;
    }

    const(char)[] read_tty_driver_name(const(char)[] name, char[] buf)
    {
        char[320] path = void;
        size_t len = make_path(path[], "/sys/class/tty/", name, "/device/driver");
        if (!len)
            return null;
        return link_target_basename(path[0 .. len], buf);
    }

    const(char)[] link_target_basename(const(char)[] link_path, char[] buf)
    {
        char[320] z = void;
        if (!copy_z(z[], link_path))
            return null;
        char[256] link = void;
        ssize_t n = readlink(z.ptr, link.ptr, link.length);
        if (n <= 0)
            return null;

        auto target = link[0 .. cast(size_t)n];
        size_t slash = 0;
        foreach_reverse (i, c; target)
        {
            if (c == '/')
            {
                slash = i + 1;
                break;
            }
        }

        auto base = target[slash .. $];
        if (base.length == 0 || base.length > buf.length)
            return null;
        buf[0 .. base.length] = base;
        return buf[0 .. base.length];
    }

    PortUsb read_usb_ident(const(char)[] tty_name, char[] manuf, char[] product, char[] serial)
    {
        PortUsb u;
        char[384] dir = void;
        size_t dn = usb_device_dir(tty_name, dir[]);
        if (!dn)
            return u;
        u.vid = read_sysfs_hex(dir[0 .. dn], "idVendor");
        u.pid = read_sysfs_hex(dir[0 .. dn], "idProduct");
        u.manufacturer = read_sysfs_str(dir[0 .. dn], "manufacturer", manuf);
        u.product = read_sysfs_str(dir[0 .. dn], "product", product);
        u.serial = read_sysfs_str(dir[0 .. dn], "serial", serial);
        return u;
    }

    // The tty's /device link points at the usb-serial port; idVendor lives a few levels up
    // on the USB device. Walk up via /.. until a level exposes it.
    size_t usb_device_dir(const(char)[] tty_name, char[] out_dir)
    {
        foreach (up; 0 .. 5)
        {
            char[384] dir = void;
            size_t n = make_path(dir[], "/sys/class/tty/", tty_name, "/device");
            if (!n)
                return 0;
            foreach (_; 0 .. up)
            {
                if (n + 3 > dir.length)
                    return 0;
                dir[n .. n + 3] = "/..";
                n += 3;
            }
            char[400] probe = void;
            size_t pn = make_path(probe[], dir[0 .. n], "/idVendor");
            if (pn && access(probe.ptr, F_OK) == 0)
            {
                if (n > out_dir.length)
                    return 0;
                out_dir[0 .. n] = dir[0 .. n];
                return n;
            }
        }
        return 0;
    }

    const(char)[] read_sysfs_str(const(char)[] dir, const(char)[] file, char[] buf)
    {
        char[400] path = void;
        size_t n = make_path(path[], dir, "/", file);
        if (!n)
            return null;
        int fd = urt.internal.sys.posix.open(path.ptr, urt.internal.sys.posix.O_RDONLY);
        if (fd < 0)
            return null;
        scope(exit) urt.internal.sys.posix.close(fd);
        ssize_t rn = urt.internal.sys.posix.read(fd, buf.ptr, buf.length);
        if (rn <= 0)
            return null;
        size_t len = cast(size_t)rn;
        while (len && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
            --len;
        return buf[0 .. len];
    }

    ushort read_sysfs_hex(const(char)[] dir, const(char)[] file)
    {
        char[16] buf = void;
        const(char)[] s = read_sysfs_str(dir, file, buf[]);
        ushort v = 0;
        foreach (c; s)
        {
            uint d;
            if (c >= '0' && c <= '9')
                d = c - '0';
            else if (c >= 'a' && c <= 'f')
                d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                d = c - 'A' + 10;
            else
                break;
            v = cast(ushort)((v << 4) | d);
        }
        return v;
    }

    void walk_dir(const(char)[] path, scope void delegate(const(char)[] name) nothrow @nogc visitor)
    {
        char[320] z = void;
        size_t len = copy_z(z[], path);
        if (len == 0)
            return;
        DIR* dir = opendir(z.ptr);
        if (dir is null)
            return;
        scope(exit) closedir(dir);

        while (true)
        {
            dirent* ent = readdir(dir);
            if (ent is null)
                break;
            size_t n;
            while (n < ent.d_name.length && ent.d_name[n] != 0)
                ++n;
            if (n == 0)
                continue;
            const(char)[] name = ent.d_name[0 .. n];
            if (name == "." || name == "..")
                continue;
            visitor(name);
        }
    }

    size_t make_path(Parts...)(char[] dst, Parts parts)
    {
        size_t n;
        foreach (part; parts)
        {
            if (n + part.length + 1 > dst.length)
                return 0;
            dst[n .. n + part.length] = part[];
            n += part.length;
        }
        dst[n] = '\0';
        return n;
    }

    size_t copy_z(char[] dst, const(char)[] src)
    {
        if (src.length + 1 > dst.length)
            return 0;
        dst[0 .. src.length] = src[];
        dst[src.length] = '\0';
        return src.length;
    }

    extern(C) nothrow @nogc
    {
        struct DIR;
        struct dirent
        {
            ulong d_ino;
            long  d_off;
            ushort d_reclen;
            ubyte  d_type;
            char[256] d_name;
        }

        DIR* opendir(const(char)* name);
        int closedir(DIR* dir);
        dirent* readdir(DIR* dir);
        int access(const(char)* pathname, int mode);
    }

    enum F_OK = 0;
}

