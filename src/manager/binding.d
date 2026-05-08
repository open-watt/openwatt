module manager.binding;

import manager.element;
import manager.subscriber;

nothrow @nogc:


class Binding : Subscriber
{
nothrow @nogc:

    void update()
    {
    }

    abstract void remove_element(Element* element);
}
