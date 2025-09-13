module manager.subscriber;

import urt.variant;

import manager.element;

nothrow @nogc:


interface Subscriber
{
nothrow @nogc:
    void on_change(Element* e, ref const Variant val, Subscriber who_made_change);
}
