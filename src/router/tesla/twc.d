module router.tesla.twc;

//###############################################################################
// Code and TWC protocol reverse engineering by Chris Dragon.
//
// Additional logs and hints provided by Teslamotorsclub.com users:
//   TheNoOne, IanAmber, and twc.
// Thank you!
//
// For support and information, please read through this thread:
// https://teslamotorsclub.com/tmc/threads/new-wall-connector-load-sharing-protocol.72830
//
// Report bugs at https://github.com/cdragon/TWCManager/issues
//
// This software is released under the "Unlicense" model: http://unlicense.org
// This means source code and TWC protocol knowledge are released to the general
// public free for personal or commercial use. I hope the knowledge will be used
// to increase the use of green energy sources by controlling the time and power
// level of car charging.
//
// WARNING:
// Misuse of the protocol described in this software can direct a Tesla Wall
// Charger to supply more current to a car than the charger wiring was designed
// for. This will trip a circuit breaker or may start a fire in the unlikely
// event that the circuit breaker fails.
// This software was not written or designed with the benefit of information from
// Tesla and there is always a small possibility that some unforeseen aspect of
// its operation could damage a Tesla vehicle or a Tesla Wall Charger. All
// efforts have been made to avoid such damage and this software is in active use
// on the author's own vehicle and TWC.
//
// In short, USE THIS SOFTWARE AT YOUR OWN RISK.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// For more information, please visit http://unlicense.org

//###############################################################################
// What's TWCManager good for?
//
// This script (TWCManager) pretends to be a Tesla Wall Charger (TWC) set to
// master mode. When wired to the IN or OUT pins of real TWC units set to slave
// mode (rotary switch position F), TWCManager can tell them to limit car
// charging to any whole amp value between 5A and the max rating of the charger.
// Charging can also be stopped so the car goes to sleep.
//
// This level of control is useful for having TWCManager track the real-time
// availability of green energy sources and direct the slave TWCs to use near the
// exact amount of energy available. This saves energy compared to sending the
// green energy off to a battery for later car charging or off to the grid where
// some of it is lost in transmission.
//
// TWCManager can also be set up to only allow charging during certain hours,
// stop charging if a grid overload or "save power day" is detected, reduce
// charging on one TWC when a "more important" one is plugged in, or whatever
// else you might want to do.
//
// One thing TWCManager does not have direct access to is the battery charge
// percentage of each plugged-in car. There are hints on forums that some TWCs
// do report battery state, but we have yet to see a TWC send such a message.
// It's possible the feature exists in TWCs with newer firmware.
// This is unfortunate, but if you own a Tesla vehicle being charged, people have
// figured out how to get its charge state by contacting Tesla's servers using
// the same password you use in the Tesla phone app. Be very careful not to
// expose that password because it allows unlocking and starting the car.

//###############################################################################
// Overview of protocol TWCs use to load share
//
// A TWC set to slave mode (rotary switch position F) sends a linkready message
// every 10 seconds.
// The message contains a unique 4-byte id that identifies that particular slave
// as the sender of the message.
//
// A TWC set to master mode sees a linkready message. In response, it sends a
// heartbeat message containing the slave's 4-byte id as the intended recipient
// of the message.
// The master's 4-byte id is included as the sender of the message.
//
// Slave sees a heartbeat message from master directed to its unique 4-byte id
// and responds with its own heartbeat message containing the master's 4-byte id
// as the intended recipient of the message.
// The slave's 4-byte id is included as the sender of the message.
//
// Master sends a heartbeat to a slave around once per second and expects a
// response heartbeat from the slave.
// Slaves do not send heartbeats without seeing one from a master first. If
// heartbeats stop coming from master, slave resumes sending linkready every 10
// seconds.
// If slaves stop replying to heartbeats from master, master stops sending
// heartbeats after about 26 seconds.
//
// Heartbeat messages contain a data block used to negotiate the amount of power
// available to each slave and to the master.
// The first byte is a status indicating things like is TWC plugged in, does it
// want power, is there an error, etc.
// Next two bytes indicate the amount of power requested or the amount allowed in
// 0.01 amp increments.
// Next two bytes indicate the amount of power being used to charge the car, also in
// 0.01 amp increments.
// Remaining bytes always contain a value of 0.

import std.socket : Socket, wouldHaveBlocked;

import manager.element;

public import router.server;
import router.stream;

import urt.endian;
import urt.log;
import urt.string;
import urt.time;


import std.stdio;
import std.conv;
import std.math;
import std.array;
import std.algorithm : min, max;
import std.array : appender;
import std.datetime : Clock, SysTime;
import std.format : format;
import std.random : uniform;
import std.regex : regex, matchFirst;
import std.stdio : writeln;

enum debugLevel = 10;

// All TWCs ship with a random two-byte TWCID. We default to using 0x7777 as our
// fake TWC ID. There is a 1 in 64535 chance that this ID will match each real
// TWC on the network, in which case you should pick a different random id below.
// This isn't really too important because even if this ID matches another TWC on
// the network, that TWC will pick its own new random ID as soon as it sees ours
// conflicts.
ubyte[2] fakeTWCID = [0x77, 0x77];

// TWCs send a seemingly-random byte after their 2-byte TWC id in a number of
// messages. I call this byte their "Sign" for lack of a better term. The byte
// never changes unless the TWC is reset or power cycled. We use hard-coded
// values for now because I don't know if there are any rules to what values can
// be chosen. I picked 77 because it's easy to recognize when looking at logs.
// These shouldn't need to be changed.
ubyte masterSign = 0x77;
ubyte slaveSign = 0x77;

ubyte[] trimPad(ubyte[] s, size_t makeLen)
{
	// Trim or pad s with zeros so that it's makeLen length
	s.length = makeLen;
	return s;
}

void sendMsg(ubyte[] msg)
{
	// ser.write(msg.formatMsg); // Implement this based on your serial communication method
	// timeLastTx = Clock.currTime(); // Update the last transmission time
}

ubyte[] frameMsg(ubyte[] msg)
{
	// On the RS485 network, we'll escape bytes with a special meaning,
	// add a CRC byte to the message end, and add a C0 byte to the start and end
	// to mark where it begins and ends.

	ubyte[128] t = void;
	size_t offset = 0;

	t[offset++] = 0xC0;

	ubyte checksum = 0;
	for (size_t i = 0; i < msg.length; i++)
	{
		checksum += msg[i];
		if (msg[i] == 0xC0)
		{
			t[offset .. offset + 2] = [0xDB, 0xDC];
			offset += 2;
		}
		else if (msg[i] == 0xDB)
		{
			t[offset .. offset + 2] = [0xDB, 0xDD];
			offset += 2;
		}
		else
			t[offset++] = msg[i];
	}
	t[offset++] = checksum & 0xFF;
	t[offset++] = 0xC0;

	return t.dup;
}

ubyte[] unescapeMsg(ubyte[] msg) nothrow @nogc
{
	size_t offset = 0;
	for (size_t i = 0; i < msg.length; i++)
	{
		if (msg[i] == 0xDB)
		{
			if (++i >= msg.length)
				return null;
			else if (msg[i] == 0xDC)
				msg[offset++] = 0xC0;
			else if (msg[i] == 0xDD)
				msg[offset++] = 0xDB;
			else
				return null;
		}
		else
		{
			if (offset < i)
				msg[offset] = msg[i];
			offset++;
		}
	}
	return msg[0 .. offset];
}

void sendMasterLinkready1()
{
	if (debugLevel >= 1)
	{
		writeln(Clock.currTime(), ": Send master linkready1");
	}

	// When master is powered on or reset, it sends 5 to 7 copies of this
	// linkready1 message followed by 5 copies of linkready2 (I've never seen
	// more or less than 5 of linkready2).
	//
	// This linkready1 message advertises master's TWCID to other slaves on the
	// network.
	// If a slave happens to have the same id as master, it will pick a new
	// random TWCID. Other than that, slaves don't seem to respond to linkready1.
	//
	// linkready1 and linkready2 are identical except FC E1 is replaced by FB E2
	// in bytes 2-3. Both messages will cause a slave to pick a new id if the
	// slave's id conflicts with master.
	// If a slave stops sending heartbeats for awhile, master may send a series
	// of linkready1 and linkready2 messages in seemingly random order, which
	// means they don't indicate any sort of startup state.
	//
	// linkready1 is not sent again after boot/reset unless a slave sends its
	// linkready message.
	// At that point, linkready1 message may start sending every 1-5 seconds, or
	// it may not be sent at all.
	// Behaviors I've seen:
	//   Not sent at all as long as slave keeps responding to heartbeat messages
	//   right from the start.
	//   If slave stops responding, then re-appears, linkready1 gets sent
	//   frequently.
	//
	// One other possible purpose of linkready1 and/or linkready2 is to trigger
	// an error condition if two TWCs on the network transmit those messages.
	// That means two TWCs have rotary switches setting them to master mode and
	// they will both flash their red LED 4 times with top green light on if that
	// happens.
	//
	// Also note that linkready1 starts with FC E1 which is similar to the FC D1
	// message that masters send out every 4 hours when idle. Oddly, the FC D1
	// message contains all zeros instead of the master's id, so it seems
	// pointless.
	//
	// I also don't understand the purpose of having both linkready1 and
	// linkready2 since only two or more linkready2 will provoke a response from
	// a slave regardless of whether linkready1 was sent previously. Firmware
	// trace shows that slaves do something somewhat complex when they receive
	// linkready1 but I haven't been curious enough to try to understand what
	// they're doing. Tests show neither linkready1 or 2 are necessary. Slaves
	// send slave linkready every 10 seconds whether or not they got master
	// linkready1/2 and if a master sees slave linkready, it will start sending
	// the slave master heartbeat once per second and the two are then connected.

	ubyte[13] msg = [0xFC, 0xE1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	msg[2 .. 4] = fakeTWCID[];
	msg[4] = masterSign;

	sendMsg(msg);
}

void sendMasterLinkready2()
{
	if (debugLevel >= 1)
	{
		writeln(Clock.currTime(), ": Send master linkready2");
	}

	// This linkready2 message is also sent 5 times when master is booted/reset
	// and then not sent again if no other TWCs are heard from on the network.
	// If the master has ever seen a slave on the network, linkready2 is sent at
	// long intervals.
	// Slaves always ignore the first linkready2, but respond to the second
	// linkready2 around 0.2s later by sending five slave linkready messages.
	//
	// It may be that this linkready2 message that sends FB E2 and the master
	// heartbeat that sends fb e0 message are really the same, (same FB byte
	// which I think is message type) except the E0 version includes the TWC ID
	// of the slave the message is intended for whereas the E2 version has no
	// recipient TWC ID.
	//
	// Once a master starts sending heartbeat messages to a slave, it
	// no longer sends the global linkready2 message (or if it does,
	// they're quite rare so I haven't seen them).

	ubyte[13] msg = [0xFB, 0xE2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	msg[2 .. 4] = fakeTWCID[];
	msg[4] = masterSign;

	sendMsg(msg);
}
/+
void sendSlaveLinkready()
{
	// In the message below, \x1F\x40 (hex 0x1f40 or 8000 in base 10) refers to
	// this being a max 80.00Amp charger model.
	// EU chargers are 32A and send 0x0c80 (3200 in base 10).
	//
	// I accidentally changed \x1f\x40 to \x2e\x69 at one point, which makes the
	// master TWC immediately start blinking its red LED 6 times with top green
	// LED on. Manual says this means "The networked Wall Connectors have
	// different maximum current capabilities".

	ubyte[15] msg = [0xFD, 0xE2, 0, 0, 0, 0x0C, 0x80, 0, 0, 0, 0, 0, 0, 0, 0];
	msg[2 .. 4] = fakeTWCID[];
	msg[4] = slaveSign;

	sendMsg(msg[0 .. protocolVersion == 2 ? 15 : 13]);
}
+/
/+
void masterIdConflict()
{
// We're playing fake slave, and we got a message from a master with our TWCID.
// By convention, as a slave we must change our TWCID because a master will not.
fakeTWCID[0] = cast(ubyte)uniform(0, 256);
fakeTWCID[1] = cast(ubyte)uniform(0, 256);

// Real slaves change their sign during a conflict, so we do too.
slaveSign[0] = cast(ubyte)uniform(0, 256);

writeln(Clock.currTime(), ": Master's TWCID matches our fake slave's TWCID. ",
"Picked new random TWCID %02X%02X with sign %02X".format(
fakeTWCID[0], fakeTWCID[1], slaveSign[0]));
}
+/

class TeslaWallConnector : Server
{
	string id;
	Stream stream;

	ushort numChargers = 1;
	ushort[4] chargerId;
	char[11][4] chargerSerial;
	char[17][4] vin;

	bool chargerOnline = false;

	this(string id, Stream stream)
	{
		super(id);

		this.id = id;
		this.stream = stream;
	}

	override bool linkEstablished()
	{
		return chargerOnline;
	}

	override void poll()
	{
		MonoTime now = getTime();

		ubyte[1024] buffer = void;
		ptrdiff_t bytes = stream.read(buffer);
		if (bytes == Socket.ERROR)
		{
			if (wouldHaveBlocked())
				bytes = 0;
			else
				assert(0);
		}
		size_t offset = 0;
		while (offset < bytes)
		{
			// scan for start of message
			while (offset < bytes && buffer[offset] != 0xC0)
				++offset;
			size_t end = offset + 1;
			for (; end < bytes; ++end)
			{
				if (buffer[end] == 0xC0)
					break;
			}

			if (offset == bytes || end == bytes)
			{
				if (bytes != buffer.length || offset == 0)
					break;
				for (size_t i = offset; i < bytes; ++i)
					buffer[i - offset] = buffer[i];
				bytes = bytes - offset;
				offset = 0;
				bytes += stream.read(buffer[bytes .. $]);
				continue;
			}

			ubyte[] msg = buffer[offset + 1 .. end];
			offset = end;

			// let's check if the message looks valid...
			if (msg.length < 13)
				continue;
			msg = unescapeMsg(msg);
			if (!msg)
				continue;
			ubyte checksum = 0;
			for (size_t i = 1; i < msg.length - 1; i++)
				checksum += msg[i];
			if (checksum != msg[$ - 1])
				continue;
			msg = msg[0 .. $-1];

			// we seem to have a valid packet...
			decodeAndPrintMessage(msg);

		}
	}

	override bool sendRequest(Request request)
	{
		// TODO: should non-modbus requests attempt to be translated based on the profile?
		assert(0);
	}

	override void requestElements(Element*[] elements)
	{
	}

private:
	int getSlaveIndex(ushort slave, bool add = false)
	{
		if (slave == 0)
			return -1;

		for (ushort i = 0; i < numChargers; ++i)
		{
			if (chargerId[i] == slave)
				return i;
		}
		if (!add)
			return -1;
		if (numChargers < 4)
		{
			writeWarningf("Add TWC slave: {0} = {1,04x}", numChargers, slave);

			chargerId[numChargers] = slave;
			return numChargers++;
		}

		writeWarningf("Can't add TWC slave, too many on bus: {0,04x}", slave);
		return -1;
	}

	void decodeAndPrintMessage(ubyte[] msg)
	{
		ushort cmd = msg[0..2].bigEndianToNative!ushort;
		switch (cmd)
		{
			case 0xFCE1: // master linkready 1
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ubyte sign = msg[4];
				if (senderId != chargerId[0])
				{
					chargerId[0] = senderId;
					writeWarningf("Found TWC master: {0,04x}", chargerId[0]);
				}
				writeWarningf("Master linkready 1:   {0,04x} - M-->   sign={1,02x} [{2}]", cmd, sign, cast(void[])msg[5..$]);
				break;
			case 0xFBE2: // master linkready 2
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ubyte sign = msg[4];
				if (senderId != chargerId[0])
				{
					chargerId[0] = senderId;
					writeWarningf("Found TWC master: {0,04x}", chargerId[0]);
				}
				writeWarningf("Master linkready 2:   {0,04x} - M-->   sign={1,02x} [{2}]", cmd, sign, cast(void[])msg[5..$]);
				break;
			case 0xFDE2: // slave linkready
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ubyte sign = msg[4];
				ushort chargerAmps = msg[5..7].bigEndianToNative!ushort;
				int slave = getSlaveIndex(senderId, true);
				writeWarningf("Slave linkready (V{0}): {1,04x} - S{2}-->  sign={3,02x} charger_current={4}A [{5}]", msg.length == 13 ? '1' : msg.length == 15 ? '2' : '?', cmd, slave, sign, cast(float)chargerAmps / 100, cast(void[])msg[7..$]);
				break;

			case 0xFBE0: // master heartbeat
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				if (senderId != chargerId[0])
				{
					chargerId[0] = senderId;
					writeWarningf("Found TWC master: {0,04x}", chargerId[0]);
				}
				int s = getSlaveIndex(receiverId, true);
				ubyte state = data[0];
				switch(state)
				{
					case 0x00: // Ready (not plugged in)
						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} READY [{2}]", cmd, s, cast(void[])data);
						break;
					case 0x05:
						ushort maxCurrent = data[1..3].bigEndianToNative!ushort;
						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} SET MAX CURRENT - current={2}A [{3}]", cmd, s, maxCurrent/100.0, cast(void[])data);
						break;
					case 0x06:
						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} REQ RAISE CURRENT [{2}]", cmd, s, cast(void[])data);
						break;
					case 0x07:
						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} REQ LOWER CURRENT [{2}]", cmd, s, cast(void[])data);
						break;
					case 0x08:
						ushort available = data[1..3].bigEndianToNative!ushort;
						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} ACK SLAVE STOPPED - avail={2}A [{3}]", cmd, s, available/100.0, cast(void[])data);
						break;
					case 0x09:
						ushort available = data[1..3].bigEndianToNative!ushort;
						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} REQ LIMIT POWER - max_cur={2}A [{3}]", cmd, s, available/100.0, cast(void[])data);
						break;
					case 0x01: // Charging
//						ushort current = data[1..3].bigEndianToNative!ushort;
//						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} CHARGING - current={2}A [{3}]", cmd, s, current/100.0, cast(void[])data);
//						break;
					case 0x02: // Error
//						break;
					case 0x03: // Plugged in, do not charge
//						ushort current = data[1..3].bigEndianToNative!ushort;
//						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} NOT CHARGING - current={2}A [{3}]", cmd, s, current/100.0, cast(void[])data);
//						break;
					case 0x04: // Plugged in, ready to charge or charge scheduled
//						break;
					case 0x0A: // Amp adjustment period complete
//						break;
					case 0x0B:
					case 0x0C:
					case 0x0D:
					case 0x0E:
					case 0x0F: // Reported once, no idea...
					default:
//						writeWarningf("Master heartbeat: {0,04x} - M-->S{1} UNKNOWN [{2}]", cmd, s, cast(void[])data);
				}
				break;
			case 0xFDE0: // slave heartbeat
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				int s = getSlaveIndex(senderId);
				ubyte state = data[0];
				switch(state)
				{
					case 0x00: // Ready (not plugged in)
						ushort current = data[1..3].bigEndianToNative!ushort;
						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M READY - current={2}A [{3}]", cmd, s, current/100.0, cast(void[])data);
						break;
					case 0x01: // Charging
						ushort available = data[1..3].bigEndianToNative!ushort;
						ushort inUse = data[3..5].bigEndianToNative!ushort;
						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M CHARGING - avail={2}A in_use={3}A [{4}]", cmd, s, available/100.0, inUse/100.0, cast(void[])data);
						break;
					case 0x03: // Plugged in, do not charge
						ushort available = data[1..3].bigEndianToNative!ushort;
						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M NOT CHARGING - avail={2}A [{3}]", cmd, s, available/100.0, cast(void[])data);
						break;
					case 0x06:
						ushort available = data[1..3].bigEndianToNative!ushort;
						ushort inUse = data[3..5].bigEndianToNative!ushort;
						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M RAISING CURRENT - avail={2}A in_use={3}A [{4}]", cmd, s, available/100.0, inUse/100.0, cast(void[])data);
						break;
					case 0x07:
						ushort available = data[1..3].bigEndianToNative!ushort;
						ushort inUse = data[3..5].bigEndianToNative!ushort;
						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M LOWERING CURRENT - avail={2}A in_use={3}A [{4}]", cmd, s, available/100.0, inUse/100.0, cast(void[])data);
						break;
					case 0x09:
						ushort available = data[1..3].bigEndianToNative!ushort;
						ushort inUse = data[3..5].bigEndianToNative!ushort;
						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M LIMIT CURRENT - cur1={2}A cur2={3}A [{4}]", cmd, s, available/100.0, inUse/100.0, cast(void[])data);
						break;
					case 0x0A: // Amp adjustment period complete ???
						ushort available = data[1..3].bigEndianToNative!ushort;
						ushort inUse = data[3..5].bigEndianToNative!ushort;
						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M STATE A - cur1={2}A cur2={3}A [{4}]", cmd, s, available/100.0, inUse/100.0, cast(void[])data);
						break;
					case 0x02: // Error
//						break;
					case 0x04: // Plugged in, ready to charge or charge scheduled
//						break;
					case 0x05: // Busy?
//						break;
					case 0x08: // Starting to charge?
//						break;
					case 0x0B:
					case 0x0C:
					case 0x0D:
					case 0x0E:
					case 0x0F: // Reported once, no idea...
					default:
//						writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M UNKNOWN - [{2}]", cmd, s, cast(void[])data);
				}

//				ubyte state = data[0];
//				ushort available = msg[1..3].bigEndianToNative!ushort;
//				ushort inUse = msg[3..5].bigEndianToNative!ushort;
//				string[16] states = [
//					"READY", "CHARGING", "ERROR", "NOTCHARGING", "READYTOCHARGE", "BUSY", "SIX", "SEVEN", "STARTINGTOCHARGE", "NINE",
//					"AMPADJUSTMENTCOMPLETE", "B?", "C?", "D?", "E?", "F? REPORTED"
//					];
//				writeWarningf("Slave heartbeat:  {0,04x} - S{1}-->M {2} {3}A {4}A [{5}]", cmd, s, states[state], available/100.0, inUse/100.0, cast(void[])data[5 .. $]);
				break;

			case 0xFBEB:
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				int s = getSlaveIndex(receiverId);
//				writeWarningf("Master unknown:   {0,04x} - M-->S{1} [{2}]", cmd, s, cast(void[])data);
				break;
			case 0xFBEC:
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				int s = getSlaveIndex(receiverId);
//				writeWarningf("Master unknown:   {0,04x} - M-->S{1} [{2}]", cmd, s, cast(void[])data);
				break;
			case 0xFBED:
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				int s = getSlaveIndex(receiverId);
//				writeWarningf("Master unknown:   {0,04x} - M-->S{1} [{2}]", cmd, s, cast(void[])data);
				break;
			case 0xFBEE:
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				int s = getSlaveIndex(receiverId);
//				writeWarningf("Master unknown:   {0,04x} - M-->S{1} [{2}]", cmd, s, cast(void[])data);
				break;
			case 0xFBEF:
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				int s = getSlaveIndex(receiverId);
//				writeWarningf("Master unknown:   {0,04x} - M-->S{1} [{2}]", cmd, s, cast(void[])data);
				break;
			case 0xFBF1:
				ushort senderId = msg[2..4].bigEndianToNative!ushort;
				ushort receiverId = msg[4..6].bigEndianToNative!ushort;
				assert(msg.length == 15);
				ubyte[9] data = msg[6..15];
				int s = getSlaveIndex(receiverId);
//				writeWarningf("Master unknown:   {0,04x} - M-->S{1} [{2}]", cmd, s, cast(void[])data);
				break;
			case 0xFDEB:
				ushort id = msg[2..4].bigEndianToNative!ushort;
				int chgId = getSlaveIndex(id);
				assert(msg.length == 19);
				ubyte[15] data = msg[4..19];
				uint totalEnergy = data[0..4].bigEndianToNative!uint;
				ushort voltage1 = data[4..6].bigEndianToNative!ushort;
				ushort voltage2 = data[6..8].bigEndianToNative!ushort;
				ushort voltage3 = data[8..10].bigEndianToNative!ushort;
				float current = data[10] / 2.0;
				float power = (voltage1*current + voltage2*current + voltage3*current) / 1000;
				writeWarningf("Report charge info:     {0,04x} - CHG{1}-->  {2}V/{3}V/{4}V {5}A {6}kW total: {7}kWh [{8}]", cmd, chgId, voltage1, voltage2, voltage3, current, power, totalEnergy, cast(void[])data);
				break;
			case 0xFDEC:
				ushort id = msg[2..4].bigEndianToNative!ushort;
				int chgId = getSlaveIndex(id);
				assert(msg.length == 15);
				ubyte[11] data = msg[4..15];
				static ubyte[11][4] lastec;
				if (chgId >= 0 && data[] != lastec[chgId][])
				{
					writeWarningf("Report EC CHANGE (CHG): {0,04x} - CHG{1}-->  [{2}]", cmd, chgId, cast(void[])data);
					lastec[chgId][] = data[];
				}
				break;
			case 0xFDED: // WTC serial
				ushort id = msg[2..4].bigEndianToNative!ushort;
				int chgId = getSlaveIndex(id);
				assert(msg.length == 19);
				if (chgId >= 0 && chargerSerial[chgId][] != (cast(char[])msg)[4..15])
				{
					chargerSerial[chgId][] = (cast(char[])msg)[4..15];
					writeWarningf("TWC SERIAL: {0,04x} - CHG{1}--> {2}", cmd, chgId, chargerSerial[chgId]);
				}
				break;
			case 0xFDEE: // VIN 0..7
				ushort id = msg[2..4].bigEndianToNative!ushort;
				int chgId = getSlaveIndex(id);
				assert(msg.length == 19);
				if (chgId >= 0 && vin[chgId][0 .. 7] != (cast(char[])msg)[4..11])
				{
					vin[chgId][0 .. 7] = (cast(char[])msg)[4..11];
					writeWarningf("VIN CHANGE: {0,04x} - CHG{1}--> {2}", cmd, chgId, vin[chgId]);
				}
				break;
			case 0xFDEF: // VIN 7..14
				ushort id = msg[2..4].bigEndianToNative!ushort;
				int chgId = getSlaveIndex(id);
				assert(msg.length == 19);
				if (chgId >= 0 && vin[chgId][7 .. 14] != (cast(char[])msg)[4..11])
				{
					vin[chgId][7 .. 14] = (cast(char[])msg)[4..11];
					writeWarningf("VIN CHANGE: {0,04x} - CHG{1}--> {2}", cmd, chgId, vin[chgId]);
				}
				break;
			case 0xFDF1: // VIN 14..17
				ushort id = msg[2..4].bigEndianToNative!ushort;
				int chgId = getSlaveIndex(id);
				assert(msg.length == 19);
				if (chgId >= 0 && vin[chgId][14 .. 17] != (cast(char[])msg)[4..7])
				{
					vin[chgId][14 .. 17] = (cast(char[])msg)[4..7];
					writeWarningf("VIN CHANGE: {0,04x} - CHG{1}--> {2}", cmd, chgId, vin[chgId]);
				}
				break;
			default:
				writeWarningf("Unknown command:  {0,04x} [{1}]", cmd, cast(void[])msg[2..$]);
				break;
		}
	}
}

/+
class TWCSlave
{
	ubyte[2] TWCID;
	double maxAmps;

	// Protocol 2 TWCs tend to respond to commands sent using protocol 1, so
	// default to that till we know for sure we're talking to protocol 2.
	int protocolVersion = 1;
	double minAmpsTWCSupports = 6;
	ubyte[] masterHeartbeatData = [0, 0, 0, 0, 0, 0, 0, 0, 0];
	SysTime timeLastRx;

	// reported* vars below are reported to us in heartbeat messages from a Slave
	// TWC.
	double reportedAmpsMax = 0;
	double reportedAmpsActual = 0;
	int reportedState = 0;

	// reportedAmpsActual frequently changes by small amounts, like 5.14A may
	// frequently change to 5.23A and back.
	// reportedAmpsActualSignificantChangeMonitor is set to reportedAmpsActual
	// whenever reportedAmpsActual is at least 0.8A different than
	// reportedAmpsActualSignificantChangeMonitor. Whenever
	// reportedAmpsActualSignificantChangeMonitor is changed,
	// timeReportedAmpsActualChangedSignificantly is set to the time of the
	// change. The value of reportedAmpsActualSignificantChangeMonitor should not
	// be used for any other purpose. timeReportedAmpsActualChangedSignificantly
	// is used for things like preventing start and stop charge on a car more
	// than once per minute.
	double reportedAmpsActualSignificantChangeMonitor = -1;
	SysTime timeReportedAmpsActualChangedSignificantly;

	double lastAmpsOffered = -1;
	SysTime timeLastAmpsOfferedChanged;
	string lastHeartbeatDebugOutput = "";
	long timeLastHeartbeatDebugOutput = 0;
	double wiringMaxAmps;

	this(ubyte[2] TWCID, double maxAmps)
	{
		this.TWCID = TWCID;
		this.maxAmps = maxAmps;
		this.timeLastRx = Clock.currTime();
		this.timeReportedAmpsActualChangedSignificantly = Clock.currTime();
		this.timeLastAmpsOfferedChanged = Clock.currTime();
		this.wiringMaxAmps = wiringMaxAmpsPerTWC;
	}

	void print_status(ubyte[] heartbeatData)
	{
		// Assuming these are global variables, you'll need to declare them somewhere
		extern bool fakeMaster;
		extern ubyte[2] masterTWCID;

		try
		{
			string debugOutput = format(": SHB %02X%02X: %02X %05.2f/%05.2fA %02X%02X", TWCID[0],
					TWCID[1], heartbeatData[0],
					(cast(double)((heartbeatData[3] << 8) + heartbeatData[4]) / 100),
					(cast(double)((heartbeatData[1] << 8) + heartbeatData[2]) / 100),
					heartbeatData[5], heartbeatData[6]);

			if (protocolVersion == 2)
			{
				debugOutput ~= format(" %02X%02X", heartbeatData[7], heartbeatData[8]);
			}
			debugOutput ~= "  M";

			if (!fakeMaster)
			{
				debugOutput ~= format(" %02X%02X", masterTWCID[0], masterTWCID[1]);
			}

			debugOutput ~= format(": %02X %05.2f/%05.2fA %02X%02X", masterHeartbeatData[0],
					(cast(double)((masterHeartbeatData[3] << 8) + masterHeartbeatData[4]) / 100),
					(cast(double)((masterHeartbeatData[1] << 8) + masterHeartbeatData[2]) / 100),
					masterHeartbeatData[5], masterHeartbeatData[6]);

			if (protocolVersion == 2)
			{
				debugOutput ~= format(" %02X%02X", masterHeartbeatData[7], masterHeartbeatData[8]);
			}

			// Only output once-per-second heartbeat debug info when it's
			// different from the last output or if the only change has been amps
			// in use and it's only changed by 1.0 or less. Also output if it's
			// been 10 mins since the last output or if debugLevel is turned up
			// to 11.
			double lastAmpsUsed = 0;
			double ampsUsed = 1;
			string debugOutputCompare = debugOutput;

			auto m1 = matchFirst(lastHeartbeatDebugOutput, regex(r"SHB ....: .. (..\...)/"));
			if (!m1.empty)
			{
				lastAmpsUsed = to!double(m1[1]);
			}

			auto m2 = matchFirst(debugOutput, regex(r"SHB ....: .. (..\...)/"));
			if (!m2.empty)
			{
				ampsUsed = to!double(m2[1]);
				if (!m1.empty)
				{
					debugOutputCompare = debugOutputCompare[0 .. m2.pre.length]
						~ lastHeartbeatDebugOutput[m1.pre.length .. m1.pre.length + m1[1].length]
						~ debugOutputCompare[m2.pre.length + m2[1].length .. $];
				}
			}

			if (debugOutputCompare != lastHeartbeatDebugOutput || abs(ampsUsed - lastAmpsUsed) >= 1.0
					|| (Clock.currTime() - timeLastHeartbeatDebugOutput).total!"seconds" > 600
					|| debugLevel >= 11)
			{
				writeln(Clock.currTime().toSimpleString(), " ", debugOutput);
				lastHeartbeatDebugOutput = debugOutput;
				timeLastHeartbeatDebugOutput = Clock.currTime();
			}
		}
		catch (Exception e)
		{
			// This happens if we try to access, say, heartbeatData[8] when
			// heartbeatData.length < 9. This was happening due to a bug I fixed
			// but I may as well leave this here just in case.
			if (heartbeatData.length != (protocolVersion == 1 ? 7 : 9))
			{
				writefln("%s: Error in print_status displaying heartbeatData %s based on msg %s",
						Clock.currTime().toSimpleString(), heartbeatData, hex_str(msg));
			}
			if (masterHeartbeatData.length != (protocolVersion == 1 ? 7 : 9))
			{
				writefln("%s: Error in print_status displaying masterHeartbeatData %s",
						Clock.currTime().toSimpleString(), masterHeartbeatData);
			}
		}
	}

	void send_slave_heartbeat(ubyte[2] masterID)
	{
		// Send slave heartbeat
		//
		// Heartbeat includes data we store in slaveHeartbeatData.
		// Meaning of data:
		//
		// Byte 1 is a state code:
		//   00 Ready
		//      Car may or may not be plugged in.
		//      When car has reached its charge target, I've repeatedly seen it
		//      change from 03 to 00 the moment I wake the car using the phone app.
		//   01 Plugged in, charging
		//   02 Error
		//      This indicates an error such as not getting a heartbeat message
		//      from Master for too long.
		//   03 Plugged in, do not charge
		//      I've seen this state briefly when plug is first inserted, and
		//      I've seen this state remain indefinitely after pressing stop
		//      charge on car's screen or when the car reaches its target charge
		//      percentage. Unfortunately, this state does not reliably remain
		//      set, so I don't think it can be used to tell when a car is done
		//      charging. It may also remain indefinitely if TWCManager script is
		//      stopped for too long while car is charging even after TWCManager
		//      is restarted. In that case, car will not charge even when start
		//      charge on screen is pressed - only re-plugging in charge cable
		//      fixes it.
		//   04 Plugged in, ready to charge or charge scheduled
		//      I've seen this state even when car is set to charge at a future
		//      time via its UI. In that case, it won't accept power offered to
		//      it.
		//   05 Busy?
		//      I've only seen it hit this state for 1 second at a time and it
		//      can seemingly happen during any other state. Maybe it means wait,
		//      I'm busy? Communicating with car?
		//   08 Starting to charge?
		//      This state may remain for a few seconds while car ramps up from
		//      0A to 1.3A, then state usually changes to 01. Sometimes car skips
		//      08 and goes directly to 01.
		//      I saw 08 consistently each time I stopped fake master script with
		//      car scheduled to charge, plugged in, charge port blue. If the car
		//      is actually charging and you stop TWCManager, after 20-30 seconds
		//      the charge port turns solid red, steering wheel display says
		//      "charge cable fault", and main screen says "check charger power".
		//      When TWCManager is started, it sees this 08 status again. If we
		//      start TWCManager and send the slave a new max power value, 08
		//      becomes 00 and car starts charging again.
		//
		//   Protocol 2 adds a number of other states:
		//   06, 07, 09
		//      These are each sent as a response to Master sending the
		//      corresponding state. Ie if Master sends 06, slave responds with
		//      06. See notes in send_master_heartbeat for meaning.
		//   0A Amp adjustment period complete
		//      Master uses state 06 and 07 to raise or lower the slave by 2A
		//      temporarily.  When that temporary period is over, it changes
		//      state to 0A.
		//   0F was reported by another user but I've not seen it during testing
		//      and have no idea what it means.
		//
		// Byte 2-3 is the max current available as provided by bytes 2-3 in our
		// fake master status.
		// For example, if bytes 2-3 are 0F A0, combine them as 0x0fa0 hex which
		// is 4000 in base 10. Move the decimal point two places left and you get
		// 40.00Amps max.
		//
		// Byte 4-5 represents the power the car is actually drawing for
		// charging. When a car is told to charge at 19A you may see a value like
		// 07 28 which is 0x728 hex or 1832 in base 10. Move the decimal point
		// two places left and you see the charger is using 18.32A.
		// Some TWCs report 0A when a car is not charging while others may report
		// small values such as 0.25A. I suspect 0A is what should be reported
		// and any small value indicates a minor calibration error.
		//
		// Remaining bytes are always 00 00 from what I've seen and could be
		// reserved for future use or may be used in a situation I've not
		// observed.  Protocol 1 uses two zero bytes while protocol 2 uses four.
		//
		//##############################
		// How was the above determined?
		//
		// An unplugged slave sends a status like this:
		//   00 00 00 00 19 00 00
		//
		// A real master always sends all 00 status data to a slave reporting the
		// above status. slaveHeartbeatData[0] is the main driver of how master
		// responds, but whether slaveHeartbeatData[1] and [2] have 00 or non-00
		// values also matters.
		//
		// I did a test with a protocol 1 TWC with fake slave sending
		// slaveHeartbeatData[0] values from 00 to ff along with
		// slaveHeartbeatData[1-2] of 00 and whatever
		// value Master last responded with. I found:
		//   Slave sends:     04 00 00 00 19 00 00
		//   Master responds: 05 12 c0 00 00 00 00
		//
		//   Slave sends:     04 12 c0 00 19 00 00
		//   Master responds: 00 00 00 00 00 00 00
		//
		//   Slave sends:     08 00 00 00 19 00 00
		//   Master responds: 08 12 c0 00 00 00 00
		//
		//   Slave sends:     08 12 c0 00 19 00 00
		//   Master responds: 00 00 00 00 00 00 00
		//
		// In other words, master always sends all 00 unless slave sends
		// slaveHeartbeatData[0] 04 or 08 with slaveHeartbeatData[1-2] both 00.
		//
		// I interpret all this to mean that when slave sends
		// slaveHeartbeatData[1-2] both 00, it's requesting a max power from
		// master. Master responds by telling the slave how much power it can
		// use. Once the slave is saying how much max power it's going to use
		// (slaveHeartbeatData[1-2] = 12 c0 = 32.00A), master indicates that's
		// fine by sending 00 00.
		//
		// However, if the master wants to set a lower limit on the slave, all it
		// has to do is send any heartbeatData[1-2] value greater than 00 00 at
		// any time and slave will respond by setting its
		// slaveHeartbeatData[1-2] to the same value.
		//
		// I thought slave might be able to negotiate a lower value if, say, the
		// car reported 40A was its max capability or if the slave itself could
		// only handle 80A, but the slave dutifully responds with the same value
		// master sends it even if that value is an insane 655.35A. I tested
		// these values on car which has a 40A limit when AC charging and
		// slave accepts them all:
		//   0f aa (40.10A)
		//   1f 40 (80.00A)
		//   1f 41 (80.01A)
		//   ff ff (655.35A)

		// Assuming these are global variables, you'll need to declare them somewhere
		extern ubyte[2] fakeTWCID;
		extern ubyte[] slaveHeartbeatData;
		extern ubyte[] overrideMasterHeartbeatData;

		if (protocolVersion == 1)
			slaveHeartbeatData.length = 7;
		else if (protocolVersion == 2)
			slaveHeartbeatData.length = 9;

		// Assuming send_msg is a global function, you'll need to declare it somewhere
		send_msg(cast(ubyte[])[0xFD, 0xE0] ~ fakeTWCID ~ masterID ~ slaveHeartbeatData);
	}

	void send_master_heartbeat()
	{
		// Send our fake master's heartbeat to this TWCSlave.
		//
		// Heartbeat includes 7 bytes (Protocol 1) or 9 bytes (Protocol 2) of data
		// that we store in masterHeartbeatData.
		//
		// Meaning of data:
		//
		// Byte 1 is a command:
		//   00 Make no changes
		//   02 Error
		//     Byte 2 appears to act as a bitmap where each set bit causes the
		//     slave TWC to enter a different error state. First 8 digits below
		//     show which bits are set and these values were tested on a Protocol
		//     2 TWC:
		//       0000 0001 = Middle LED blinks 3 times red, top LED solid green.
		//                   Manual says this code means 'Incorrect rotary switch
		//                   setting.'
		//       0000 0010 = Middle LED blinks 5 times red, top LED solid green.
		//                   Manual says this code means 'More than three Wall
		//                   Connectors are set to Slave.'
		//       0000 0100 = Middle LED blinks 6 times red, top LED solid green.
		//                   Manual says this code means 'The networked Wall
		//                   Connectors have different maximum current
		//                   capabilities.'
		//   	0000 1000 = No effect
		//   	0001 0000 = No effect
		//   	0010 0000 = No effect
		//   	0100 0000 = No effect
		//       1000 0000 = No effect
		//     When two bits are set, the lowest bit (rightmost bit) seems to
		//     take precedence (ie 111 results in 3 blinks, 110 results in 5
		//     blinks).
		//
		//     If you send 02 to a slave TWC with an error code that triggers
		//     the middle LED to blink red, slave responds with 02 in its
		//     heartbeat, then stops sending heartbeat and refuses further
		//     communication. Slave's error state can be cleared by holding red
		//     reset button on its left side for about 4 seconds.
		//     If you send an error code with bitmap 11110xxx (where x is any bit),
		//     the error can not be cleared with a 4-second reset.  Instead, you
		//     must power cycle the TWC or 'reboot' reset which means holding
		//     reset for about 6 seconds till all the LEDs turn green.
		//   05 Tell slave charger to limit power to number of amps in bytes 2-3.
		//
		// Protocol 2 adds a few more command codes:
		//   06 Increase charge current by 2 amps.  Slave changes its heartbeat
		//      state to 06 in response. After 44 seconds, slave state changes to
		//      0A but amp value doesn't change.  This state seems to be used to
		//      safely creep up the amp value of a slave when the Master has extra
		//      power to distribute.  If a slave is attached to a car that doesn't
		//      want that many amps, Master will see the car isn't accepting the
		//      amps and stop offering more.  It's possible the 0A state change
		//      is not time based but rather indicates something like the car is
		//      now using as many amps as it's going to use.
		//   07 Lower charge current by 2 amps. Slave changes its heartbeat state
		//      to 07 in response. After 10 seconds, slave raises its amp setting
		//      back up by 2A and changes state to 0A.
		//      I could be wrong, but when a real car doesn't want the higher amp
		//      value, I think the TWC doesn't raise by 2A after 10 seconds. Real
		//      Master TWCs seem to send 07 state to all children periodically as
		//      if to check if they're willing to accept lower amp values. If
		//      they do, Master assigns those amps to a different slave using the
		//      06 state.
		//   08 Master acknowledges that slave stopped charging (I think), but
		//      the next two bytes contain an amp value the slave could be using.
		//   09 Tell slave charger to limit power to number of amps in bytes 2-3.
		//      This command replaces the 05 command in Protocol 1. However, 05
		//      continues to be used, but only to set an amp value to be used
		//      before a car starts charging. If 05 is sent after a car is
		//      already charging, it is ignored.
		//
		// Byte 2-3 is the max current a slave TWC can charge at in command codes
		// 05, 08, and 09. In command code 02, byte 2 is a bitmap. With other
		// command codes, bytes 2-3 are ignored.
		// If bytes 2-3 are an amp value of 0F A0, combine them as 0x0fa0 hex
		// which is 4000 in base 10. Move the decimal point two places left and
		// you get 40.00Amps max.
		//
		// Byte 4: 01 when a Master TWC is physically plugged in to a car.
		// Otherwise 00.
		//
		// Remaining bytes are always 00.
		//
		// Example 7-byte data that real masters have sent in Protocol 1:
		//   00 00 00 00 00 00 00  (Idle)
		//   02 04 00 00 00 00 00  (Error bitmap 04.  This happened when I
		//                         advertised a fake Master using an invalid max
		//                         amp value)
		//   05 0f a0 00 00 00 00  (Master telling slave to limit power to 0f a0
		//                         (40.00A))
		//   05 07 d0 01 00 00 00  (Master plugged in to a car and presumably
		//                          telling slaves to limit power to 07 d0
		//                          (20.00A). 01 byte indicates Master is plugged
		//                          in to a car.)

		// Assuming these are global variables and functions, you'll need to declare them somewhere
		extern ubyte[2] fakeTWCID;
		extern ubyte[] overrideMasterHeartbeatData;
		extern int debugLevel;
		extern SysTime timeLastTx;
		extern Car[] carApiVehicles;

		if (overrideMasterHeartbeatData.length >= 7)
		{
			masterHeartbeatData = overrideMasterHeartbeatData.dup;
		}

		if (protocolVersion == 2)
		{
			// TODO: Start and stop charging using protocol 2 commands to TWC
			// instead of car api if I ever figure out how.
			if (lastAmpsOffered == 0 && reportedAmpsActual > 4.0)
			{
				// Car is trying to charge, so stop it via car API.
				// car_api_charge() will prevent telling the car to start or stop
				// more than once per minute. Once the car gets the message to
				// stop, reportedAmpsActualSignificantChangeMonitor should drop
				// to near zero within a few seconds.
				// WARNING: If you own two vehicles and one is charging at home but
				// the other is charging away from home, this command will stop
				// them both from charging.  If the away vehicle is not currently
				// charging, I'm not sure if this would prevent it from charging
				// when next plugged in.
				queue_background_task(["cmd": "charge", "charge": false]);
			}
			else if (lastAmpsOffered >= 5.0 && reportedAmpsActual < 2.0 && reportedState != 0x02)
			{
				// Car is not charging and is not reporting an error state, so
				// try starting charge via car api.
				queue_background_task(["cmd": "charge", "charge": true]);
			}
			else if (reportedAmpsActual > 4.0)
			{
				// At least one plugged in car is successfully charging. We don't
				// know which car it is, so we must set
				// vehicle.stopAskingToStartCharging = False on all vehicles such
				// that if any vehicle is not charging without us calling
				// car_api_charge(False), we'll try to start it charging again at
				// least once. This probably isn't necessary but might prevent
				// some unexpected case from never starting a charge. It also
				// seems less confusing to see in the output that we always try
				// to start API charging after the car stops taking a charge.
				foreach (vehicle; carApiVehicles)
				{
					vehicle.stopAskingToStartCharging = false;
				}
			}
		}

		send_msg(cast(ubyte[])[0xFB, 0xE0] ~ fakeTWCID ~ TWCID ~ masterHeartbeatData);
	}

	void receive_slave_heartbeat(ubyte[] heartbeatData)
	{
		// Handle heartbeat message received from real slave TWC.
		import std.conv;
		import std.math;
		import core.sync.mutex;

		float nonScheduledAmpsMax;
		float maxAmpsToDivideAmongSlaves;
		float wiringMaxAmpsAllTWCs;
		SysTime timeLastGreenEnergyCheck;
		float greenEnergyAmpsOffset;
		float chargeNowAmps;
		SysTime chargeNowTimeEnd;
		float minAmpsPerTWC;
		int scheduledAmpsDaysBitmap;
		int scheduledAmpsStartHour;
		int scheduledAmpsEndHour;
		int hourResumeTrackGreenEnergy;
		int debugLevel;

		auto backgroundTasksLock = new Mutex;
		// ...

		SysTime now = Clock.currTime();
		this.timeLastRx = now;

		this.reportedAmpsMax = ((heartbeatData[1] << 8) + heartbeatData[2]) / 100.0;
		this.reportedAmpsActual = ((heartbeatData[3] << 8) + heartbeatData[4]) / 100.0;
		this.reportedState = heartbeatData[0];

		if (this.lastAmpsOffered < 0)
		{
			this.lastAmpsOffered = this.reportedAmpsMax;
		}

		if (this.reportedAmpsActualSignificantChangeMonitor < 0
				|| abs(this.reportedAmpsActual - this.reportedAmpsActualSignificantChangeMonitor) > 0.8)
		{
			this.timeReportedAmpsActualChangedSignificantly = now;
			this.reportedAmpsActualSignificantChangeMonitor = this.reportedAmpsActual;
		}

		SysTime ltNow = Clock.currTime().toLocalTime();
		float hourNow = ltNow.hour + (ltNow.minute / 60.0);
		int yesterday = ltNow.day - 1;
		if (yesterday < 0)
		{
			yesterday += 7;
		}

		// Check if it's time to resume tracking green energy.
		if (nonScheduledAmpsMax != -1 && hourResumeTrackGreenEnergy > -1
				&& hourResumeTrackGreenEnergy == hourNow)
		{
			nonScheduledAmpsMax = -1;
			save_settings();
		}

		// Check if we're within the hours we must use scheduledAmpsMax instead
		// of nonScheduledAmpsMax
		bool blnUseScheduledAmps = false;
		if (scheduledAmpsMax > 0 && scheduledAmpsStartHour > -1
				&& scheduledAmpsEndHour > -1 && scheduledAmpsDaysBitmap > 0)
		{
			if (scheduledAmpsStartHour > scheduledAmpsEndHour)
			{
				if ((hourNow >= scheduledAmpsStartHour && (scheduledAmpsDaysBitmap & (1 << ltNow.weekday)))
						|| (hourNow < scheduledAmpsEndHour
							&& (scheduledAmpsDaysBitmap & (1 << yesterday))))
				{
					blnUseScheduledAmps = true;
				}
			}
			else
			{
				if (hourNow >= scheduledAmpsStartHour && hourNow < scheduledAmpsEndHour
						&& (scheduledAmpsDaysBitmap & (1 << ltNow.weekday)))
				{
					blnUseScheduledAmps = true;
				}
			}
		}

		if (chargeNowTimeEnd > 0 && chargeNowTimeEnd < now)
		{
			chargeNowAmps = 0;
			chargeNowTimeEnd = SysTime(0);
		}

		if (chargeNowTimeEnd > 0 && chargeNowAmps > 0)
		{
			maxAmpsToDivideAmongSlaves = chargeNowAmps;
			if (debugLevel >= 10)
			{
				writeln(Clock.currTime()
						.toISOExtString() ~ ": Charge at chargeNowAmps ", chargeNowAmps);
			}
		}
		else if (blnUseScheduledAmps)
		{
			maxAmpsToDivideAmongSlaves = scheduledAmpsMax;
		}
		else
		{
			if (nonScheduledAmpsMax > -1)
			{
				maxAmpsToDivideAmongSlaves = nonScheduledAmpsMax;
			}
			else if (now - timeLastGreenEnergyCheck > 60.seconds)
			{
				timeLastGreenEnergyCheck = now;

				if (ltNow.hour < 6 || ltNow.hour >= 20)
				{
					maxAmpsToDivideAmongSlaves = 0;
				}
				else
				{
					queue_background_task(["cmd": "checkGreenEnergy"]);
				}
			}
		}

		synchronized (backgroundTasksLock)
		{
			if (maxAmpsToDivideAmongSlaves > wiringMaxAmpsAllTWCs)
			{
				if (debugLevel >= 1)
				{
					writeln(Clock.currTime()
							.toISOExtString() ~ " ERROR: maxAmpsToDivideAmongSlaves ",
							maxAmpsToDivideAmongSlaves, " > wiringMaxAmpsAllTWCs ",
							wiringMaxAmpsAllTWCs,
							".\nSee notes above wiringMaxAmpsAllTWCs in the 'Configuration parameters' section.");
				}
				maxAmpsToDivideAmongSlaves = wiringMaxAmpsAllTWCs;
			}

			int numCarsCharging = 1;
			float desiredAmpsOffered = maxAmpsToDivideAmongSlaves;
			foreach (slaveTWC; slaveTWCRoundRobin)
			{
				if (slaveTWC.TWCID != this.TWCID)
				{
					desiredAmpsOffered -= slaveTWC.reportedAmpsActual;
					if (slaveTWC.reportedAmpsActual >= 1.0)
					{
						numCarsCharging++;
					}
				}
			}

			float fairShareAmps = cast(int)(maxAmpsToDivideAmongSlaves / numCarsCharging);
			if (desiredAmpsOffered > fairShareAmps)
			{
				desiredAmpsOffered = fairShareAmps;
			}

			if (debugLevel >= 10)
			{
				writeln("desiredAmpsOffered reduced from ", maxAmpsToDivideAmongSlaves, " to ",
						desiredAmpsOffered, " with ", numCarsCharging, " cars charging.");
			}
		}

		float minAmpsToOffer = minAmpsPerTWC;
		if (this.minAmpsTWCSupports > minAmpsToOffer)
		{
			minAmpsToOffer = this.minAmpsTWCSupports;
		}

		if (desiredAmpsOffered < minAmpsToOffer)
		{
			if (maxAmpsToDivideAmongSlaves / numCarsCharging > minAmpsToOffer)
			{
				if (debugLevel >= 10)
				{
					writeln("desiredAmpsOffered increased from ", desiredAmpsOffered,
							" to ", this.minAmpsTWCSupports, " (self.minAmpsTWCSupports)");
				}
				desiredAmpsOffered = this.minAmpsTWCSupports;
			}
			else
			{
				if (debugLevel >= 10)
				{
					writeln("desiredAmpsOffered reduced to 0 from ",
							desiredAmpsOffered, " because maxAmpsToDivideAmongSlaves ",
							maxAmpsToDivideAmongSlaves,
							" / numCarsCharging ", numCarsCharging,
							" < minAmpsToOffer ", minAmpsToOffer);
				}
				desiredAmpsOffered = 0;
			}

			if (this.lastAmpsOffered > 0 && (now - this.timeLastAmpsOfferedChanged < 60.seconds
					|| now - this.timeReportedAmpsActualChangedSignificantly < 60.seconds
					|| this.reportedAmpsActual < 4.0))
			{
				if (debugLevel >= 10)
				{
					writeln("Don't stop charging yet because: ",
							"time - this.timeLastAmpsOfferedChanged ",
							(now - this.timeLastAmpsOfferedChanged).total!"seconds",
							" < 60 or time - this.timeReportedAmpsActualChangedSignificantly ",
							(now - this.timeReportedAmpsActualChangedSignificantly)
								.total!"seconds", " < 60 or this.reportedAmpsActual ",
							this.reportedAmpsActual, " < 4");
				}
				desiredAmpsOffered = minAmpsToOffer;
			}
		}
		else
		{
			desiredAmpsOffered = cast(int)(desiredAmpsOffered);

			if (this.lastAmpsOffered == 0 && now - this.timeLastAmpsOfferedChanged < 60.seconds)
			{
				if (debugLevel >= 10)
				{
					writeln("Don't start charging yet because: ",
							"this.lastAmpsOffered ", this.lastAmpsOffered, " == 0 ",
							"and time - this.timeLastAmpsOfferedChanged ",
							(now - this.timeLastAmpsOfferedChanged).total!"seconds", " < 60");
				}
				desiredAmpsOffered = this.lastAmpsOffered;
			}
			else
			{
				if (debugLevel >= 10)
				{
					writeln("desiredAmpsOffered=", desiredAmpsOffered,
							" spikeAmpsToCancel6ALimit=",
							spikeAmpsToCancel6ALimit, " this.lastAmpsOffered=",
							this.lastAmpsOffered, " this.reportedAmpsActual=",
							this.reportedAmpsActual,
							" now - this.timeReportedAmpsActualChangedSignificantly=",
							(now - this.timeReportedAmpsActualChangedSignificantly)
								.total!"seconds");
				}

				if ((desiredAmpsOffered < spikeAmpsToCancel6ALimit
						&& desiredAmpsOffered > this.lastAmpsOffered) || (this.reportedAmpsActual > 2.0
						&& this.reportedAmpsActual <= spikeAmpsToCancel6ALimit
						&& (this.lastAmpsOffered - this.reportedAmpsActual) > 2.0
						&& now - this.timeReportedAmpsActualChangedSignificantly > 10.seconds))
				{
					if (this.lastAmpsOffered == spikeAmpsToCancel6ALimit
							&& now - this.timeLastAmpsOfferedChanged > 10.seconds)
					{
						if (debugLevel >= 1)
						{
							writeln(Clock.currTime()
									.toISOExtString()
									~ ": Car stuck when offered spikeAmpsToCancel6ALimit. Offering 2 less.");
						}
						desiredAmpsOffered = spikeAmpsToCancel6ALimit - 2.0;
					}
					else if (now - this.timeLastAmpsOfferedChanged > 5.seconds)
					{
						desiredAmpsOffered = spikeAmpsToCancel6ALimit;
					}
					else
					{
						desiredAmpsOffered = this.lastAmpsOffered;
					}
				}
				else if (desiredAmpsOffered < this.lastAmpsOffered)
				{
					if (debugLevel >= 10)
					{
						writeln("Reduce amps: time - this.timeLastAmpsOfferedChanged ",
								(now - this.timeLastAmpsOfferedChanged).total!"seconds");
					}
					if (now - this.timeLastAmpsOfferedChanged < 5.seconds)
					{
						desiredAmpsOffered = this.lastAmpsOffered;
					}
				}
			}
		}

		desiredAmpsOffered = this.set_last_amps_offered(desiredAmpsOffered);

		if (this.reportedAmpsMax != desiredAmpsOffered || desiredAmpsOffered == 0)
		{
			int desiredHundredthsOfAmps = cast(int)(desiredAmpsOffered * 100);
			this.masterHeartbeatData = cast(ubyte[])[
				(this.protocolVersion == 2 ? 0x09 : 0x05),
				(desiredHundredthsOfAmps >> 8) & 0xFF,
				desiredHundredthsOfAmps & 0xFF, 0, 0, 0, 0, 0, 0
			];
		}
		else
		{
			this.masterHeartbeatData = cast(ubyte[])[0, 0, 0, 0, 0, 0, 0, 0, 0];
		}

		if (overrideMasterHeartbeatData.length >= 7)
		{
			this.masterHeartbeatData = overrideMasterHeartbeatData;
		}

		if (debugLevel >= 1)
		{
			this.print_status(heartbeatData);
		}
	}

	float set_last_amps_offered(float desiredAmpsOffered)
	{
		import std.algorithm : max;

		if (debugLevel >= 10)
		{
			writeln("set_last_amps_offered(TWCID=", hex(this.TWCID),
					", desiredAmpsOffered=", desiredAmpsOffered, ")");
		}

		if (desiredAmpsOffered != this.lastAmpsOffered)
		{
			float oldLastAmpsOffered = this.lastAmpsOffered;
			this.lastAmpsOffered = desiredAmpsOffered;

			float totalAmpsAllTWCs = total_amps_actual_all_twcs()
				- this.reportedAmpsActual + this.lastAmpsOffered;
			if (totalAmpsAllTWCs > wiringMaxAmpsAllTWCs)
			{
				this.lastAmpsOffered = cast(int)(wiringMaxAmpsAllTWCs - (
						total_amps_actual_all_twcs() - this.reportedAmpsActual));

				if (this.lastAmpsOffered < this.minAmpsTWCSupports)
				{
					this.lastAmpsOffered = this.minAmpsTWCSupports;
				}

				writeln("WARNING: Offering slave TWC ", this.TWCID.to!string,
						" ", this.lastAmpsOffered, "A instead of ",
						desiredAmpsOffered, "A to avoid overloading wiring shared by all TWCs.");
			}

			if (this.lastAmpsOffered > this.wiringMaxAmps)
			{
				this.lastAmpsOffered = this.wiringMaxAmps;
				if (debugLevel >= 10)
				{
					writeln("Offering slave TWC ", this.TWCID.to!string, " ",
							this.lastAmpsOffered, "A instead of ", desiredAmpsOffered,
							"A to avoid overloading the TWC rated at ", this.wiringMaxAmps, "A.");
				}
			}

			if (this.lastAmpsOffered != oldLastAmpsOffered)
			{
				this.timeLastAmpsOfferedChanged = Clock.currTime();
			}
		}
		return this.lastAmpsOffered;
	}
}
+/

