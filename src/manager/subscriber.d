module manager.subscriber;

import urt.variant;

import manager.element;

nothrow @nogc:


interface Subscriber
{
nothrow @nogc:
    void onChange(Element* e, ref const Variant val, Subscriber whoMadeChange);
}
