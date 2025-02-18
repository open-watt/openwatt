module protocol.mqtt;

import urt.string;

import manager.console;
import manager.plugin;

import protocol.mqtt.broker;


class MQTTModule : Module
{
	mixin DeclareModule!"protocol.mqtt";

	MQTTBroker broker;

	override void init()
	{
	}

	override void update()
	{
//		if (broker)
//			broker.update();
	}
}


private:
