module router.stream.serial;

import std.format;
import std.stdio;

public import router.stream;

import urt.string.format;

struct SerialParams
{
	this(int baud)
	{
		this.baudRate = baud;
	}

	int baudRate = 9600;
	int dataBits = 8;
	int stopBits = 1;
	// parity?
}

version(Windows)
{
	import core.sys.windows.windows;
	import std.conv : to;
	import std.string : toStringz;

	class SerialStream : Stream
	{
		this(string device, in SerialParams serialParams, StreamOptions options = StreamOptions.None)
		{
			super(options);
			this.device = device;
			this.params = serialParams;
		}

		override bool connect()
		{
			wchar[256] buf;
			wstring wstr = device.to!wstring;
			assert(wstr.length < buf.length);
			buf[0..wstr.length] = wstr[];
			buf[wstr.length] = 0;

			hCom = CreateFile(buf.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
			if (hCom == INVALID_HANDLE_VALUE)
			{
				writeln("CreateFile failed with error %d.\n", GetLastError());
				return false;
			}

			DCB dcbSerialParams;
			ZeroMemory(&dcbSerialParams, DCB.sizeof);
			dcbSerialParams.DCBlength = DCB.sizeof;
			if (!GetCommState(hCom, &dcbSerialParams))
			{
				CloseHandle(hCom);
				hCom = INVALID_HANDLE_VALUE;

				writeln("GetCommState failed with error %d.\n", GetLastError());
				return false;
			}

			dcbSerialParams.BaudRate = DWORD(params.baudRate);
			dcbSerialParams.ByteSize = 8;
			dcbSerialParams.StopBits = ONESTOPBIT;
			dcbSerialParams.Parity = NOPARITY;

			if (!SetCommState(hCom, &dcbSerialParams))
			{
				CloseHandle(hCom);
				hCom = INVALID_HANDLE_VALUE;

				writeln("Error to Setting DCB Structure.\n");
				return false;
			}

			COMMTIMEOUTS timeouts = {};
			timeouts.ReadIntervalTimeout = 50;
			timeouts.ReadTotalTimeoutConstant = 50;
			timeouts.ReadTotalTimeoutMultiplier = 10;
			timeouts.WriteTotalTimeoutConstant = 50;
			timeouts.WriteTotalTimeoutMultiplier = 10;
			if (!SetCommTimeouts(hCom, &timeouts))
			{
				CloseHandle(hCom);
				hCom = INVALID_HANDLE_VALUE;

				writeln("Error to Setting Time outs.\n");
				return false;
			}

			writeln(format("Opened %s: 0x%x", device, hCom));
			return true;
		}

		override void disconnect()
		{
			CloseHandle(hCom);
			hCom = INVALID_HANDLE_VALUE;
		}

		override bool connected()
		{
			return hCom == INVALID_HANDLE_VALUE;
		}

		override ptrdiff_t read(ubyte[] buffer)
		{
			DWORD bytesRead;
			if (ReadFile(hCom, buffer.ptr, cast(DWORD)buffer.length, &bytesRead, null))
			{
				return bytesRead;
			}
			else
			{
				// Handle error
				return -1;
			}
		}

		override ptrdiff_t write(const ubyte[] data)
		{
			DWORD bytesWritten;
			if (WriteFile(hCom, data.ptr, cast(DWORD)data.length, &bytesWritten, null))
			{
				return bytesWritten;
			}
			else
			{
				// Handle error
				return -1;
			}
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
		HANDLE hCom = INVALID_HANDLE_VALUE;
		string device;
		SerialParams params;
	}
}
else version(Posix)
{
	import core.sys.posix.termios;
	import core.sys.posix.unistd;
	import core.sys.posix.fcntl;
	import core.stdc.stdint : ptrdiff_t;
	import std.string : toStringz;

	class SerialStream : Stream
	{
		this(string device, in SerialParams serialParams, StreamOptions options = StreamOptions.None)
		{
			this.device = device;
			this.params = serialParams;
			this.options = options;
		}

		override bool connect()
		{
			fd = core.sys.posix.fcntl.open(device.toStringz(), O_RDWR | O_NOCTTY | O_NDELAY);
			if (fd == -1)
			{
				writeln("Failed to open device %s.\n", params.device);
			}

			termios tty;
			tcgetattr(fd, &tty);

			cfsetospeed(&tty, params.baudRate);
			cfsetispeed(&tty, params.baudRate);

			tty.c_cflag &= ~PARENB; // Clear parity bit
			tty.c_cflag &= ~CSTOPB; // Clear stop field
			tty.c_cflag &= ~CSIZE;  // Clear size bits
			tty.c_cflag |= CS8;	 // 8 bits per byte
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

			tty.c_cc[VTIME] = 1;	// Wait for up to 1 deciseconds, return as soon as any data is received
			tty.c_cc[VMIN] = 0;

			if (tcsetattr(fd, TCSANOW, &tty) != 0)
			{
				// Handle error
			}
			return true;
		}

		override void disconnect()
		{
			close(fd);
			fd = -1;
		}

		override ptrdiff_t read(ubyte[] buffer)
		{
			ssize_t bytesRead = read(fd, buffer.ptr, buffer.length);
			return bytesRead;
		}

		override ptrdiff_t write(const ubyte[] data)
		{
			ssize_t bytesWritten = write(fd, buffer.ptr, buffer.length);
			return bytesWritten;
		}

	private:
		int fd = -1;
		string device;
		SerialParams params;
		StreamOptions options;
	}
}
else
{
	static assert(false, "No serial implementation!");
}
