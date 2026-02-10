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
    import core.sys.windows.windows;
}
else version(Posix)
{
//    import urt.internal.os;
    import core.sys.linux.termios;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;
    import core.sys.posix.sys.types;
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
    __gshared Property[6] Properties = [ Property.create!("device", device)(),
                                         Property.create!("baud-rate", baud_rate)(),
                                         Property.create!("data-bits", data_bits)(),
                                         Property.create!("parity", parity)(),
                                         Property.create!("stop-bits", stop_bits)(),
                                         Property.create!("flow-control", flow_control)() ];
nothrow @nogc:

    alias TypeName = StringLit!"serial";

    this(String name, ObjectFlags flags = ObjectFlags.none, StreamOptions options = StreamOptions.none)
    {
        super(collection_type_info!SerialStream, name.move, flags, options);
    }

    // Properties...

    String device() const pure
        => _device;
    StringResult device(String value)
    {
        if (!value)
            return StringResult("device cannot be empty");
        if (_device == value)
            return StringResult.success;
        _device = value.move;
        restart();
        return StringResult.success;
    }

    uint baud_rate() const pure
        => _params.baud_rate;
    StringResult baud_rate(uint value)
    {
        if (value == 0)
            return StringResult("baud rate must be greater than 0");
        if (_params.baud_rate == value)
            return StringResult.success;
        _params.baud_rate = value;
        restart();
        return StringResult.success;
    }

    uint data_bits() const pure
        => _params.data_bits;
    StringResult data_bits(uint value)
    {
        if (value < 5 || value > 9)
            return StringResult("data bits must be between 5 and 9");
        if (_params.data_bits == cast(ubyte)value)
            return StringResult.success;
        _params.data_bits = cast(ubyte)value;
        restart();
        return StringResult.success;
    }

    Parity parity() const pure
        => _params.parity;
    void parity(Parity value)
    {
        if (_params.parity == value)
            return;
        _params.parity = value;
        restart();
    }

    StopBits stop_bits() const pure
        => _params.stop_bits;
    void stop_bits(StopBits value)
    {
        if (_params.stop_bits == value)
            return;
        _params.stop_bits = value;
        restart();
    }

    FlowControl flow_control() const pure
        => _params.flow_control;
    void flow_control(FlowControl value)
    {
        if (_params.flow_control == value)
            return;
        _params.flow_control = value;
        restart();
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

            DCB dcb;
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
            _fd = core.sys.posix.fcntl.open(device.tstringz, O_RDWR | O_NOCTTY | O_NDELAY);
            if (_fd == -1)
            {
                writeln("Failed to open device %s.\n", this.device);
                return CompletionStatus.error;
            }

            termios tty;
            tcgetattr(_fd, &tty);

            cfsetospeed(&tty, _params.baud_rate);
            cfsetispeed(&tty, _params.baud_rate);

            tty.c_cflag &= ~PARENB; // Clear parity bit
            tty.c_cflag &= ~CSTOPB; // Clear stop field
            tty.c_cflag &= ~CSIZE;  // Clear size bits
            tty.c_cflag |= CS8;     // 8 bits per byte
            tty.c_cflag &= ~CRTSCTS;// Disable RTS/CTS hardware flow control
            tty.c_cflag |= CREAD | CLOCAL; // Turn on READ & ignore ctrl lines

            tty.c_lflag &= ~ICANON;
            tty.c_lflag &= ~ECHO;   // Disable echo
            tty.c_lflag &= ~ECHOE;  // Disable erasure
            tty.c_lflag &= ~ECHONL; // Disable new-line echo
            tty.c_lflag &= ~ISIG;   // Disable interpretation of INTR, QUIT and SUSP
            tty.c_iflag &= ~(IXON | IXOFF | IXANY); // Turn off s/w flow ctrl
            tty.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL); // Disable any special handling of received bytes

            tty.c_oflag &= ~OPOST; // Prevent special interpretation of output bytes (e.g. newline chars)
            tty.c_oflag &= ~ONLCR; // Prevent conversion of newline to carriage return/line feed

            tty.c_cc[VTIME] = 1;    // Wait for up to 1 deciseconds, return as soon as any data is received
            tty.c_cc[VMIN] = 0;

            if (tcsetattr(_fd, TCSANOW, &tty) != 0)
            {
                // Handle error ???
                return CompletionStatus.error;
            }
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
                core.sys.posix.unistd.close(_fd);
                _fd = -1;
            }
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
        else
        {
            // TODO
            assert(false, "TODO: test to see if the port is live...");
        }
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
            if (_logging)
                write_to_log(true, buffer[0 .. bytes_read]);
            return bytes_read;
        }
        else version(Posix)
        {
            ssize_t bytes_read = core.sys.posix.unistd.read(_fd, buffer.ptr, buffer.length);
            if (_logging)
                write_to_log(true, buffer[0 .. bytes_read]);
            return bytes_read;
        }
    }

    override ptrdiff_t write(const void[] data)
    {
        version(Windows)
        {
            DWORD bytes_written;
            if (!WriteFile(_h_com, data.ptr, cast(DWORD)data.length, &bytes_written, null))
            {
                restart();
                return -1;
            }
            if (_logging)
                write_to_log(false, data[0 .. bytes_written]);
            return bytes_written;
        }
        else version(Posix)
        {
            ssize_t bytes_written = core.sys.posix.unistd.write(_fd, data.ptr, data.length);
            if (_logging)
                write_to_log(false, data[0 .. bytes_written]);
            return bytes_written;
        }
    }

    override const(char)[] remote_name()
    {
        return _device[];
    }

    override ptrdiff_t pending()
    {
        // TODO:?
        assert(0);
    }

    override ptrdiff_t flush()
    {
        // TODO: just read until can't read anymore?
        assert(0);
    }

private:
    version (Windows)
        HANDLE _h_com = INVALID_HANDLE_VALUE;
    else version (Posix)
        int _fd = -1;

    String _device;
    SerialParams _params;
}


class SerialStreamModule : Module
{
    mixin DeclareModule!"stream.serial";
nothrow @nogc:

    Collection!SerialStream serial_streams;

    override void init()
    {
        g_app.register_enum!StopBits();
        g_app.register_enum!Parity();
        g_app.register_enum!FlowControl();

        g_app.console.register_collection("/stream/serial", serial_streams);
    }

    override void pre_update()
    {
        serial_streams.update_all();
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
