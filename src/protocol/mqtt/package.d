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
			app.console.registerCommand("/protocol", new MQTTCommand(app.console, this));
		}

		override void update()
		{
			if (broker)
				broker.update();
		}
	}
}


private:

class MQTTCommand : Collection
{
	import manager.console.expression;

	MQTTModule.Instance instance;

	this(ref Console console, MQTTModule.Instance instance)
	{
		import urt.mem.string;

		super(console, StringLit!"mqtt", cast(Collection.Features)(Collection.Features.AddRemove | Collection.Features.SetUnset | Collection.Features.EnableDisable | Collection.Features.Print | Collection.Features.Comment));
		this.instance = instance;
	}

	override void add(KVP[] params)
	{
	}

	override void remove(const(char)[] item)
	{
		int x = 0;
	}

	override void set(const(char)[] item, KVP[] params)
	{
		int x = 0;
	}

	override void print(KVP[] params)
	{
		int x = 0;
	}
}
