module protocol.mqtt;

import urt.string;

import manager.console;
import manager.plugin;

import protocol.mqtt.broker;


class MQTTModule : Plugin
{
	mixin RegisterModule!"mqtt";

	class Instance : Plugin.Instance
	{
		mixin DeclareInstance;

		MQTTBroker broker;

		override void init()
		{
		}

		override void update()
		{
			if (broker)
				broker.update();
		}
	}
}


private:
