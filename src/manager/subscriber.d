module manager.subscriber;

import manager.element;
import manager.value;

interface Subscriber
{
	void onChange(Element* e, Value val, Subscriber whoMadeChange);


}
