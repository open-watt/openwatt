module manager.subscriber;

import manager.element;
import manager.value;

nothrow @nogc:


interface Subscriber
{
nothrow @nogc:
	void onChange(Element* e, ref const Value val, Subscriber whoMadeChange);
}
