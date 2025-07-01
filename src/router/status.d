module router.status;

import urt.time;

nothrow @nogc:


struct Status
{
nothrow @nogc:
    enum Connection : byte
    {
        Unknown = -1,
        Disconnected = 0,
        Connected
    }

    enum Link : byte
    {
        Unknown = -1,
        Down = 0,
        Up
    }

    SysTime linkStatusChangeTime;
    bool enabled;
    Connection connected = Connection.Unknown;
    Link linkStatus = Link.Down;
    int linkDowns;

    ulong sendBytes;
    ulong recvBytes;
    ulong sendPackets;
    ulong recvPackets;
    ulong sendDropped;
    ulong recvDropped;

    ulong txLinkSpeed;
    ulong rxLinkSpeed;
}
