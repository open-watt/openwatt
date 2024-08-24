module protocol.tesla.twc;

import urt.endian;


enum TWCMessageType : byte
{
	Unknown = -1,
	MasterLinkReady1 = 0,	// FCE1
	MasterLinkReady2,		// FBE2
	SlaveLinkReady,			// FDE2
	MasterHeartbeat,		// FBE0
	SlaveHeartbeat,			// FDE0
	_FBEB,
	_FBEC,
	_FBED,
	_FBEE,
	_FBEF,
	_FBF1,
	ChargeInfo,
	_FDEC, // ???
	TWCSerialNumber,
	VIN1,
	VIN2,
	VIN3,
}

enum TWCState : ubyte
{
	Ready = 0,
	Charging,
	Error,
	PluggedIn_DoNotCharge,
	PluggedIn_ChargeScheduled,
	Busy,	// ???
	RaisingCurrent,
	LoweringCurrent,
	StartingToCharge, // ???
	LimitCurrent,
	_A, // ??? Amp adjustment period complete? It sends this sometimes...
	_B,
	_C,
	_D,
	_E,
	_F	// ??? Reported once, no idea!
}

struct TWCMessage
{
	ushort cmd;
	ushort sender;
	ushort receiver;
	TWCMessageType type = TWCMessageType.Unknown;
	ubyte ver;
	union
	{
		LinkReady linkready;
		Heartbeat heartbeat;
		ChargeInfo chargeinfo;
		char[11] sn;			// Charger serial number
		char[7] vin1;			// VIN 1-7
		char[7] vin2;			// VIN 8-14
		char[3] vin3;			// VIN 15-17
	}

	struct LinkReady
	{
		ubyte signature;		// A weird byte that changes each reset, but is like a device 'signature'?
		ushort amps;			// A * 100
	}
	struct Heartbeat
	{
		TWCState state;
		ushort current;
		ushort currentInUse;
	}
	struct ChargeInfo
	{
		uint lifetimeEnergy;	// Lifetime energy delivery for this charger
		ushort voltage1;		// V - Phase 1
		ushort voltage2;		// V - Phase 2
		ushort voltage3;		// V - Phase 3
		ubyte current;			// A * 2
	}
}

bool parseTWCMessage(const(ubyte)[] data, out TWCMessage msg)
{
	ushort cmd = data[0..2].bigEndianToNative!ushort;
	foreach (i, c; messageCode[])
	{
		if (c == cmd)
		{
			msg.type = cast(TWCMessageType)i;
			break;
		}
	}
	if (msg.type == TWCMessageType.Unknown)
		return false;

	msg.cmd = cmd;
	msg.ver = data.length == 13 ? 1 : data.length == 15 ? 2 : 0;

	switch (msg.type)
	{
		case TWCMessageType.MasterLinkReady1:
		case TWCMessageType.MasterLinkReady2:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			msg.linkready.signature = data[4];
			break;
		case TWCMessageType.SlaveLinkReady:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			msg.linkready.signature = data[4];
			msg.linkready.amps = data[5..7].bigEndianToNative!ushort;
			break;
		case TWCMessageType.MasterHeartbeat:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			msg.receiver = data[4..6].bigEndianToNative!ushort;
			if (!msg.ver == 2)
				return false;
			ubyte[9] params = data[6..15];
			msg.heartbeat.state = cast(TWCState)params[0];
			if (msg.heartbeat.state > 0xF)
				return false;
			switch (msg.heartbeat.state)
			{
				case 0x05:
				case 0x08:
				case 0x09:
					msg.heartbeat.current = params[1..3].bigEndianToNative!ushort;
					break;
				default:
					break;
			}
			break;
		case TWCMessageType.SlaveHeartbeat:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			msg.receiver = data[4..6].bigEndianToNative!ushort;
			if (!msg.ver == 2)
				return false;
			ubyte[9] params = data[6..15];
			msg.heartbeat.state = cast(TWCState)params[0];
			if (msg.heartbeat.state > 0xF)
				return false;
			switch (msg.heartbeat.state)
			{
				case 0x01:
				case 0x06:
				case 0x07:
				case 0x09:
				case 0x0A:
					msg.heartbeat.currentInUse = params[3..5].bigEndianToNative!ushort;
					goto case;
				case 0x00:
				case 0x03:
					msg.heartbeat.current = params[3..5].bigEndianToNative!ushort;
					break;
				default:
					break;
			}
			break;
		case TWCMessageType._FBEB:
		case TWCMessageType._FBEC:
		case TWCMessageType._FBED:
		case TWCMessageType._FBEE:
		case TWCMessageType._FBEF:
		case TWCMessageType._FBF1:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			msg.receiver = data[4..6].bigEndianToNative!ushort;
			if (!msg.ver == 2)
				return false;
			ubyte[9] params = data[6..15];
			//...
			break;
		case TWCMessageType.ChargeInfo:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			if (data.length != 19)
				return false;
			msg.ver = 2;
			ubyte[15] params = data[4..19];
			msg.chargeinfo.lifetimeEnergy = params[0..4].bigEndianToNative!uint;
			msg.chargeinfo.voltage1 = params[4..6].bigEndianToNative!ushort;
			msg.chargeinfo.voltage2 = params[6..8].bigEndianToNative!ushort;
			msg.chargeinfo.voltage3 = params[8..10].bigEndianToNative!ushort;
			msg.chargeinfo.current = params[10];
			break;
		case TWCMessageType._FDEC:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			break;
		case TWCMessageType.TWCSerialNumber:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			if (data.length != 19)
				return false;
			msg.ver = 2;
			msg.sn[] = cast(char[])data[4..15];
			break;
		case TWCMessageType.VIN1:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			if (data.length != 19)
				return false;
			msg.ver = 2;
			msg.vin1[] = cast(char[])data[4..11];
			break;
		case TWCMessageType.VIN2:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			if (data.length != 19)
				return false;
			msg.ver = 2;
			msg.vin2[] = cast(char[])data[4..11];
			break;
		case TWCMessageType.VIN3:
			msg.sender = data[2..4].bigEndianToNative!ushort;
			if (data.length != 19)
				return false;
			msg.ver = 2;
			msg.vin3[] = cast(char[])data[4..7];
			break;
		default:
			assert(false);
	}
	return true;
}



private:

__gshared immutable ushort[] messageCode = [
	0xFCE1, 0xFBE2, 0xFDE2, 0xFBE0,
	0xFDE0, 0xFBEB, 0xFBEC, 0xFBED,
	0xFBEE, 0xFBEF, 0xFBF1, 0xFDEB,
	0xFDEC, 0xFDED, 0xFDEE, 0xFDEF,
	0xFDF1
];
