module manager.subscriber;

import urt.time;
import urt.variant;

import manager.element;

nothrow @nogc:


interface Subscriber
{
nothrow @nogc:
    void on_change(Element* e, ref const Variant val, SysTime timestamp, Subscriber who_made_change);
}
