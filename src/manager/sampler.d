module manager.sampler;

import manager.element;
import manager.subscriber;

nothrow @nogc:


class Sampler : Subscriber
{
nothrow @nogc:

    void update()
    {
    }

    abstract void removeElement(Element* element);
}
