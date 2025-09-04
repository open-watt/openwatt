module router.stream.serial;

import urt.io;
import urt.lifetime;
import urt.log;
import urt.meta.nullable;
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
    One,
    OnePointFive,
    Two,
}

enum Parity : ubyte
{
    None,
    Even,
    Odd,
    Mark,
    Space
}

enum FlowControl : ubyte
{
    None,
    Hardware,
    Software,
    DSR_DTR,

    RTS_CTS = Hardware,
    XON_XOFF = Software
}

struct SerialParams
{
    this(int baud)
    {
        this.baudRate = baud;
    }

    uint baudRate = 9600;
    ubyte dataBits = 8;
    StopBits stopBits = StopBits.One;
    Parity parity = Parity.None;
    FlowControl flowControl = FlowControl.None;
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

    this(String name, ObjectFlags flags = ObjectFlags.None, StreamOptions options = StreamOptions.None)
    {
        super(collectionTypeInfo!SerialStream, name.move, flags, options);
    }

    // Properties...

    String device() const pure
        => _device;
    const(char)[] device(String value)
    {
        if (!value)
            return "device cannot be empty";
        if (_device == value)
            return null;
        _device = value.move;
        restart();
        return null;
    }

    uint baud_rate() const pure
        => params.baudRate;
    const(char)[] baud_rate(uint value)
    {
        if (value == 0)
            return "baud rate must be greater than 0";
        if (params.baudRate == value)
            return null;
        params.baudRate = value;
        restart();
        return null;
    }

    uint data_bits() const pure
        => params.dataBits;
    const(char)[] data_bits(uint value)
    {
        if (value < 5 || value > 9)
            return "data bits must be between 5 and 9";
        if (params.dataBits == cast(ubyte)value)
            return null;
        params.dataBits = cast(ubyte)value;
        restart();
        return null;
    }

    Parity parity() const pure
        => params.parity;
    void parity(Parity value)
    {
        if (params.parity == value)
            return;
        params.parity = value;
        restart();
    }

    StopBits stop_bits() const pure
        => params.stopBits;
    void stop_bits(StopBits value)
    {
        if (params.stopBits == value)
            return;
        params.stopBits = value;
        restart();
    }

    FlowControl flow_control() const pure
        => params.flowControl;
    void flow_control(FlowControl value)
    {
        if (params.flowControl == value)
            return;
        params.flowControl = value;
        restart();
    }

    // API...

    final override bool validate() const
        => !_device.empty;

    override CompletionStatus startup()
    {
        version(Windows)
        {
            hCom = CreateFile(device.twstringz, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if (hCom == INVALID_HANDLE_VALUE)
                return CompletionStatus.Error;

            DCB dcb;
            ZeroMemory(&dcb, DCB.sizeof);
            dcb.DCBlength = DCB.sizeof;
            if (!GetCommState(hCom, &dcb))
                return CompletionStatus.Error;

            dcb._bf = 1;

            dcb.BaudRate = DWORD(params.baudRate);
            dcb.ByteSize = params.dataBits;

            if (params.stopBits == StopBits.One)
                dcb.StopBits = ONESTOPBIT;
            else if (params.stopBits == StopBits.OnePointFive)
                dcb.StopBits = ONE5STOPBITS;
            else if (params.stopBits == StopBits.Two)
                dcb.StopBits = TWOSTOPBITS;

            switch (params.parity)
            {
                case Parity.None:   dcb.Parity = NOPARITY;      break;
                case Parity.Even:   dcb.Parity = EVENPARITY;    break;
                case Parity.Odd:    dcb.Parity = ODDPARITY;     break;
                case Parity.Mark:   dcb.Parity = MARKPARITY;    break;
                case Parity.Space:  dcb.Parity = SPACEPARITY;   break;
                default: assert(false);
            }
            if (params.parity != Parity.None)
                dcb._bf |= 2; // fParity: set to enable parity checking?

            switch (params.flowControl)
            {
                case FlowControl.None:
                    dcb._bf &= ~4; // fOutxCtsFlow
                    dcb._bf &= ~8; // fOutxDsrFlow
                    dcb._bf &= ~0x40; // fDsrSensitivity
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.Disable << 12; // fRtsControl
                    dcb._bf |= DTRControl.Disable << 4; // fDtrControl
                    break;
                case FlowControl.Hardware:
                    dcb._bf |= 4; // fOutxCtsFlow
                    dcb._bf &= ~8; // fOutxDsrFlow
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.Handshake << 12; // fRtsControl
//                    dcb._bf |= RTSControl.Enable << 12; // fRtsControl
                    dcb._bf |= DTRControl.Enable << 4; // fDtrControl
                    break;
                case FlowControl.Software:
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
                    dcb._bf |= RTSControl.Disable << 12; // fRtsControl
                    dcb._bf |= DTRControl.Enable << 4; // fDtrControl
                    break;
                case FlowControl.DSR_DTR:
                    dcb._bf &= ~4; // fOutxCtsFlow
                    dcb._bf |= 8; // fOutxDsrFlow
                    dcb._bf |= 0x40; // fDsrSensitivity
                    dcb._bf &= ~0x100; // fOutX
                    dcb._bf &= ~0x200; // fInX
                    dcb._bf &= ~0x3030;
                    dcb._bf |= RTSControl.Disable << 12; // fRtsControl
                    dcb._bf |= DTRControl.Handshake << 4; // fDtrControl
                    break;
                default:
                    assert(false);
            }

            if (!SetCommState(hCom, &dcb))
                return CompletionStatus.Error;

            COMMTIMEOUTS timeouts = {};
            timeouts.ReadIntervalTimeout = -1;
            timeouts.ReadTotalTimeoutConstant = 0;
            timeouts.ReadTotalTimeoutMultiplier = 0;
            timeouts.WriteTotalTimeoutConstant = 0;
            timeouts.WriteTotalTimeoutMultiplier = 0;
            if (!SetCommTimeouts(hCom, &timeouts))
                return CompletionStatus.Error;
        }
        else version(Posix)
        {
            fd = core.sys.posix.fcntl.open(device.tstringz, O_RDWR | O_NOCTTY | O_NDELAY);
            if (fd == -1)
            {
                writeln("Failed to open device %s.\n", this.device);
                return CompletionStatus.Error;
            }

            termios tty;
            tcgetattr(fd, &tty);

            cfsetospeed(&tty, params.baudRate);
            cfsetispeed(&tty, params.baudRate);

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

            if (tcsetattr(fd, TCSANOW, &tty) != 0)
            {
                // Handle error ???
                return CompletionStatus.Error;
            }
        }
        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        version (Windows)
        {
            if (hCom != INVALID_HANDLE_VALUE)
                CloseHandle(hCom);
            hCom = INVALID_HANDLE_VALUE;
        }
        else version (Posix)
        {
            if (fd != -1)
            {
                core.sys.posix.unistd.close(fd);
                fd = -1;
            }
        }
        return CompletionStatus.Complete;
    }


    override void update()
    {
        version(Windows)
        {
            DWORD errors;
            COMSTAT stat;
            if (ClearCommError(hCom, &errors, &stat))
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
            DWORD bytesRead;
            if (!ReadFile(hCom, buffer.ptr, cast(DWORD)buffer.length, &bytesRead, null))
            {
                restart();
                return -1;
            }
            if (logging)
                writeToLog(true, buffer[0 .. bytesRead]);
            return bytesRead;
        }
        else version(Posix)
        {
            ssize_t bytesRead = core.sys.posix.unistd.read(fd, buffer.ptr, buffer.length);
            if (logging)
                writeToLog(true, buffer[0 .. bytesRead]);
            return bytesRead;
        }
    }

    override ptrdiff_t write(const void[] data)
    {
        version(Windows)
        {
            DWORD bytesWritten;
            if (!WriteFile(hCom, data.ptr, cast(DWORD)data.length, &bytesWritten, null))
            {
                restart();
                return -1;
            }
            if (logging)
                writeToLog(false, data[0 .. bytesWritten]);
            return bytesWritten;
        }
        else version(Posix)
        {
            ssize_t bytesWritten = core.sys.posix.unistd.write(fd, data.ptr, data.length);
            if (logging)
                writeToLog(false, data[0 .. bytesWritten]);
            return bytesWritten;
        }
    }

    override const(char)[] remoteName()
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
        HANDLE hCom = INVALID_HANDLE_VALUE;
    else version (Posix)
        int fd = -1;

    String _device;
    SerialParams params;
}


class SerialStreamModule : Module
{
    mixin DeclareModule!"stream.serial";
nothrow @nogc:

    Collection!SerialStream serial_streams;

    override void init()
    {
        g_app.console.registerCollection("/stream/serial", serial_streams);
    }
}


private:

version(Windows)
{
    enum RTSControl : ubyte
    {
        Disable, Enable, Handshake, Toggle
    }
    enum DTRControl : ubyte
    {
        Disable, Enable, Handshake
    }
}
