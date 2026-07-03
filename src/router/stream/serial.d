module router.stream.serial;

import urt.io;
import urt.lifetime;
import urt.log;
import urt.meta.nullable;
import urt.result;
import urt.string;
import urt.string.format;

import manager;
import manager.collection;
import manager.console.session;
import manager.plugin;

public import router.stream;

version (Windows)
{
    import urt.internal.sys.windows;
}
else version(Posix)
{
    import urt.internal.sys.posix;
    import urt.internal.sys.posix.termios;
    import urt.internal.stdc.errno : EAGAIN, EWOULDBLOCK, EINTR;
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
            _h_com = CreateFile(_device[].twstringz, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if (_h_com == INVALID_HANDLE_VALUE)
                return CompletionStatus.error;

            DCB dcb = void;
            ZeroMemory(&dcb, DCB.sizeof);
            dcb.DCBlength = DCB.sizeof;
            if (!GetCommState(_h_com, &dcb))
                return CompletionStatus.error;

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

            switch (_params.flow_control)
            {
                case FlowControl.none:
                    dcb._bf &= ~4; // fOutxCtsFlow
                    dcb._bf &= ~8; // fOutxDsrFlow
                    dcb._bf &= ~0x40; // fDsrSensitivity
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.disable << 12; // fRtsControl
                    dcb._bf |= DTRControl.disable << 4; // fDtrControl
                    break;
                case FlowControl.hardware:
                    dcb._bf |= 4; // fOutxCtsFlow
                    dcb._bf &= ~8; // fOutxDsrFlow
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.handshake << 12; // fRtsControl
//                    dcb._bf |= RTSControl.enable << 12; // fRtsControl
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
                    dcb._bf |= RTSControl.disable << 12; // fRtsControl
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
                return CompletionStatus.error;

            COMMTIMEOUTS timeouts = {};
            timeouts.ReadIntervalTimeout = -1;
            timeouts.ReadTotalTimeoutConstant = 0;
            timeouts.ReadTotalTimeoutMultiplier = 0;
            timeouts.WriteTotalTimeoutConstant = 0;
            timeouts.WriteTotalTimeoutMultiplier = 0;
            if (!SetCommTimeouts(_h_com, &timeouts))
                return CompletionStatus.error;
        }
        else version(Posix)
        {
            _fd = urt.internal.sys.posix.open(device[].tstringz, O_RDWR | O_NOCTTY | O_NDELAY);
            if (_fd == -1)
            {
                writeln("Failed to open device ", this.device);
                return CompletionStatus.error;
            }

            termios tty;
            if (tcgetattr(_fd, &tty) != 0)
                return fail_posix_startup();

            speed_t speed;
            bool custom_baud = !posix_baud(_params.baud_rate, speed);
            if (custom_baud)
            {
                version (linux) {}
                else
                {
                    writeln("Unsupported serial baud rate ", _params.baud_rate);
                    return fail_posix_startup();
                }
            }
            else
            {
                if (cfsetospeed(&tty, speed) != 0 || cfsetispeed(&tty, speed) != 0)
                    return fail_posix_startup();
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
                writeln("POSIX serial does not support 1.5 stop bits");
                return fail_posix_startup();
            }

            tty.c_cflag &= ~CSIZE;
            switch (_params.data_bits)
            {
                case 5: tty.c_cflag |= CS5; break;
                case 6: tty.c_cflag |= CS6; break;
                case 7: tty.c_cflag |= CS7; break;
                case 8: tty.c_cflag |= CS8; break;
                default:
                    writeln("POSIX serial does not support ", _params.data_bits, " data bits");
                    return fail_posix_startup();
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
                    writeln("POSIX serial does not support DSR/DTR flow control");
                    return fail_posix_startup();
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
                return fail_posix_startup();
            if (custom_baud)
            {
                version (linux)
                {
                    if (!set_linux_custom_baud(_fd, _params.baud_rate))
                    {
                        writeln("Unsupported serial baud rate ", _params.baud_rate);
                        return fail_posix_startup();
                    }
                }
            }
            tcflush(_fd, TCIOFLUSH);
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
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        version (Windows)
        {
            if (_h_com != INVALID_HANDLE_VALUE)
                CloseHandle(_h_com);
            _h_com = INVALID_HANDLE_VALUE;
        }
        else version (Posix)
        {
            if (_fd != -1)
            {
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
        version(Windows)
        {
            DWORD errors;
            COMSTAT stat;
            if (ClearCommError(_h_com, &errors, &stat))
            {
                if (errors != 0)
                {
                    assert(false, "TODO: test this case");
                    restart();
                }
            }
            else
                restart();
        }
        else version (Embedded)
        {
            uart_poll(_uart);
            if (uart_check_errors(_uart) != UartError.none)
                restart();
        }

        super.update();
    }

    override ptrdiff_t read(void[] buffer)
    {
        version(Windows)
        {
            DWORD bytes_read;
            if (!ReadFile(_h_com, buffer.ptr, cast(DWORD)buffer.length, &bytes_read, null))
            {
                restart();
                return -1;
            }
        }
        else version(Posix)
        {
            ssize_t bytes_read = urt.internal.sys.posix.read(_fd, buffer.ptr, buffer.length);
            if (bytes_read < 0)
            {
                if (is_transient_errno())
                    return 0;
                restart();
                return -1;
            }
        }
        else version (Embedded)
            ptrdiff_t bytes_read = uart_read(_uart, buffer);

        if (bytes_read > 0)
            add_rx_bytes(bytes_read);
        if (_logging && bytes_read > 0)
            write_to_log(true, buffer[0 .. bytes_read]);
        return bytes_read;
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

            DWORD _bytes_written;
            if (!WriteFile(_h_com, send_buffer.ptr, cast(DWORD)send_buffer.length, &_bytes_written, null))
            {
                restart();
                return -1;
            }

            bytes_written = _bytes_written;
            if (_logging)
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
                    if (_logging)
                        write_to_log(false, buf[0 .. n]);
                    buf = buf[n .. $];
                }
            }
        posix_write_done:
        }
        else version (Embedded)
        {
            bytes_written = uart_writev(_uart, data);
            if (_logging && bytes_written > 0)
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

    override ptrdiff_t pending()
    {
        version (Windows)
        {
            DWORD errors;
            COMSTAT stat;
            if (!ClearCommError(_h_com, &errors, &stat))
                return 0;
            return stat.cbInQue;
        }
        else version (Posix)
        {
            int avail;
            if (ioctl(_fd, FIONREAD, &avail) < 0)
                return 0;
            return avail;
        }
        else
        {
        version (Embedded)
            return cast(ptrdiff_t)uart_rx_available(_uart);
        }
    }

    override ptrdiff_t flush()
    {
        version (Windows)
        {
            PurgeComm(_h_com, PURGE_TXABORT | PURGE_RXABORT | PURGE_TXCLEAR | PURGE_RXCLEAR);
            return 0;
        }
        else version (Posix)
        {
            tcdrain(_fd);
            tcflush(_fd, TCIOFLUSH);
            return 0;
        }
        else version (Embedded)
        {
            uart_tx_flush(_uart);
            return 0;
        }
    }

private:
    version (Windows)
        HANDLE _h_com = INVALID_HANDLE_VALUE;
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

    version (Posix)
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

    override void init()
    {
        g_app.register_enum!StopBits();
        g_app.register_enum!Parity();
        g_app.register_enum!FlowControl();

        g_app.console.register_collection!SerialStream();
        version (Posix)
            g_app.console.register_command!serial_devices("/stream/serial", this, "devices");
    }
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

    uint list_serial_ttys(Session session)
    {
        uint count;
        walk_dir("/sys/class/tty", (const(char)[] name) nothrow @nogc {
            if (!is_serial_tty(name))
                return;
            char[320] path = void;
            size_t n = make_path(path[], "/dev/", name);
            if (n)
            {
                session.write_line(path[0 .. n]);
                ++count;
            }
        });
        return count;
    }

    uint list_serial_dir(Session session, const(char)[] dir, const(char)[] prefix)
    {
        uint count;
        walk_dir(dir, (const(char)[] name) nothrow @nogc {
            if (prefix && !name.startsWith(prefix))
                return;
            char[512] path = void;
            size_t n = make_path(path[], dir, "/", name);
            if (n)
            {
                session.write_line(path[0 .. n]);
                ++count;
            }
        });
        return count;
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
