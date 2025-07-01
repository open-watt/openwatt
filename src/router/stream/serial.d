module router.stream.serial;

import urt.io;
import urt.lifetime;
import urt.log;
import urt.meta.nullable;
import urt.string;
import urt.string.format;

import manager;
import manager.console.session;
import manager.plugin;

public import router.stream;


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

version(Windows)
{
    import core.sys.windows.windows;
    import std.conv : to;
    import std.string : toStringz;

    enum RTSControl : ubyte
    {
        Disable, Enable, Handshake, Toggle
    }
    enum DTRControl : ubyte
    {
        Disable, Enable, Handshake
    }

    class SerialStream : Stream
    {
    nothrow @nogc:

        alias TypeName = StringLit!"serial";

        this(String name, String device, in SerialParams serialParams, StreamOptions options = StreamOptions.None)
        {
            assert(serialParams.dataBits >= 5 || serialParams.dataBits <= 8);

            // TODO: The use of 5 data bits with 2 stop bits is an invalid combination, as is 6, 7, or 8 data bits with 1.5 stop bits.

            super(name.move, TypeName, options);
            this.device = device.move;
            this.params = serialParams;

            connect();
        }

        override bool connect()
        {
            hCom = CreateFile(device.twstringz, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
            if (hCom == INVALID_HANDLE_VALUE)
                return false;

            DCB dcb;
            ZeroMemory(&dcb, DCB.sizeof);
            dcb.DCBlength = DCB.sizeof;
            if (!GetCommState(hCom, &dcb))
            {
                CloseHandle(hCom);
                hCom = INVALID_HANDLE_VALUE;
                return false;
            }

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
                case Parity.None:    dcb.Parity = NOPARITY;        break;
                case Parity.Even:    dcb.Parity = EVENPARITY;    break;
                case Parity.Odd:    dcb.Parity = ODDPARITY;        break;
                case Parity.Mark:    dcb.Parity = MARKPARITY;    break;
                case Parity.Space:    dcb.Parity = SPACEPARITY;    break;
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
            {
                CloseHandle(hCom);
                hCom = INVALID_HANDLE_VALUE;
                return false;
            }

            COMMTIMEOUTS timeouts = {};
            timeouts.ReadIntervalTimeout = -1;
            timeouts.ReadTotalTimeoutConstant = 0;
            timeouts.ReadTotalTimeoutMultiplier = 0;
            timeouts.WriteTotalTimeoutConstant = 0;
            timeouts.WriteTotalTimeoutMultiplier = 0;
            if (!SetCommTimeouts(hCom, &timeouts))
            {
                CloseHandle(hCom);
                hCom = INVALID_HANDLE_VALUE;
                return false;
            }

            status.linkStatus = Status.Link.Up;

            return true;
        }

        override void disconnect()
        {
            if (hCom != INVALID_HANDLE_VALUE)
                CloseHandle(hCom);
            hCom = INVALID_HANDLE_VALUE;
            status.linkStatus = Status.Link.Down;
        }

        override bool connected()
        {
            if (hCom == INVALID_HANDLE_VALUE)
                status.linkStatus = Status.Link.Down;
            if (status.linkStatus != Status.Link.Up)
                return false;

            DWORD errors;
            COMSTAT status;
            if (ClearCommError(hCom, &errors, &status))
            {
                if (errors == 0)
                    return true;
                else
                {
                    assert(false, "TODO: test this case");
                    return false; // close the port?
                }
            }

            disconnect();
            return false;
        }

        override const(char)[] remoteName()
        {
            return device[];
        }

        override void setOpts(StreamOptions options)
        {
            this.options = options;
        }

        override ptrdiff_t read(void[] buffer)
        {
            DWORD bytesRead;
            if (!ReadFile(hCom, buffer.ptr, cast(DWORD)buffer.length, &bytesRead, null))
            {
                CloseHandle(hCom);
                hCom = INVALID_HANDLE_VALUE;
                status.linkStatus = Status.Link.Down;
                return -1;
            }
            if (logging)
                writeToLog(true, buffer[0 .. bytesRead]);
            return bytesRead;
        }

        override ptrdiff_t write(const void[] data)
        {
            DWORD bytesWritten;
            if (!WriteFile(hCom, data.ptr, cast(DWORD)data.length, &bytesWritten, null))
            {
                CloseHandle(hCom);
                hCom = INVALID_HANDLE_VALUE;
                status.linkStatus = Status.Link.Down;
                return -1;
            }
            if (logging)
                writeToLog(false, data[0 .. bytesWritten]);
            return bytesWritten;
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

        override void update()
        {
            if (hCom == INVALID_HANDLE_VALUE)
                return;

            if (status.linkStatus == Status.Link.Up)
            {
                DWORD errors;
                COMSTAT stat;
                if (ClearCommError(hCom, &errors, &stat))
                {
                    if (errors == 0)
                        status.linkStatus = Status.Link.Up;
                    else
                    {
                        assert(false, "TODO: test this case");
                        status.linkStatus = Status.Link.Down; // close the port?
                    }
                }
                else
                    disconnect();
            }

            // this should implement keep-alive nonsense and all that...
            // what if the port comes and goes? we need to re-scan for the device if it's plugged/unplugged, etc.

            if (status.linkStatus != Status.Link.Up)
                connect();
        }

    private:
        String device;
        SerialParams params;
        HANDLE hCom = INVALID_HANDLE_VALUE;
    }
}
else version(Posix)
{

//    import urt.internal.os;
    import core.sys.linux.termios;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;
    import core.sys.posix.sys.types;
    import std.string : toStringz;

    class SerialStream : Stream
    {
    nothrow @nogc:

        alias TypeName = StringLit!"serial";

        this(String name, String device, in SerialParams serialParams, StreamOptions options = StreamOptions.None)
        {
            super(name.move, TypeName, options);
            this.device = device;
            this.params = serialParams;
        }

        override bool connect()
        {
            fd = core.sys.posix.fcntl.open(device.tstringz, O_RDWR | O_NOCTTY | O_NDELAY);
            if (fd == -1)
            {
                writeln("Failed to open device %s.\n", this.device);
                return false;
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
                // Handle error
            }
            return true;
        }

        override void disconnect()
        {
            core.sys.posix.unistd.close(fd);
            fd = -1;
        }

        override bool connected()
        {
            if (fd == -1)
                status.linkStatus = Status.Link.Down;
            if (status.linkStatus != Status.Link.Up)
                return false;
            // TODO
            assert(false);
//            DWORD errors;
//            COMSTAT status;
//            if (ClearCommError(hCom, &errors, &status))
//            {
//                if (errors == 0)
//                    return true;
//                else
//                {
//                    assert(false, "TODO: test this case");
//                    return false; // close the port?
//                }
//            }
//
//            disconnect();
            return false;
        }

        override const(char)[] remoteName()
        {
            return device[];
        }

        override void setOpts(StreamOptions options)
        {
            this.options = options;
        }


        override ptrdiff_t read(void[] buffer)
        {
            ssize_t bytesRead = core.sys.posix.unistd.read(fd, buffer.ptr, buffer.length);
            if (logging)
                writeToLog(true, buffer[0 .. bytesRead]);
            return bytesRead;
        }

        override ptrdiff_t write(const void[] data)
        {
            ssize_t bytesWritten = core.sys.posix.unistd.write(fd, data.ptr, data.length);
            if (logging)
                writeToLog(false, data[0 .. bytesWritten]);
            return bytesWritten;
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

        override void update()
        {
            // this should implement keep-alive nonsense and all that...
            // what if the port comes and goes? we need to re-scan for the device if it's plugged/unplugged, etc.

            if (status.linkStatus != Status.Link.Up)
                connect();
        }

    private:
        int fd = -1;
        String device;
        SerialParams params;
        StreamOptions options;
    }
}
else
{
    static assert(false, "No serial implementation!");
}


class SerialStreamModule : Module
{
    mixin DeclareModule!"stream.serial";
nothrow @nogc:

    override void init()
    {
        g_app.console.registerCommand!add("/stream/serial", this);
    }

    void add(Session session, const(char)[] name, const(char)[] device, int baud, Nullable!int data_bits, Nullable!float stop_bits, Nullable!Parity parity, Nullable!FlowControl flow_control)
    {
        auto mod_stream = getModule!StreamModule;

        if (name.empty)
            mod_stream.generateStreamName("serial-stream");

        // TODO: assert data bits == 7,8, stop bits == 1,1.5,2, verify other enums...

        SerialParams params;
        params.baudRate = baud;
        params.dataBits = data_bits ? cast(ubyte)data_bits.value : 8;
        params.stopBits = stop_bits ? cast(StopBits)(stop_bits.value*2 - 2) : StopBits.One;
        params.parity = parity ? parity.value : Parity.None;
        params.flowControl = flow_control ? flow_control.value : FlowControl.None;

        String n = name.makeString(g_app.allocator);
        String dev = device.makeString(g_app.allocator);

        SerialStream stream = g_app.allocator.allocT!SerialStream(n.move, dev.move, params, cast(StreamOptions)(StreamOptions.NonBlocking | StreamOptions.KeepAlive));
        mod_stream.addStream(stream);

        writeInfof("Create Serial stream '{0}' - device: {1}@{2}", name, device, params.baudRate);
    }
}
