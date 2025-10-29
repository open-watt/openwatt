module protocol.zigbee.sampler;

import urt.array;
import urt.si.quantity;
import urt.variant;

import manager.element;
import manager.sampler;
import manager.subscriber;

import protocol.tesla;
import protocol.tesla.master;

import router.iface.mac;

nothrow @nogc:


class ZigbeeSampler : Sampler
{
nothrow @nogc:

    this()
    {
    }

    final override void update()
    {
    }
}
