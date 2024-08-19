module manager.protocol.modbus;

import urt.string;

import manager;
import manager.console;
import manager.console.command;
import manager.console.session;
import manager.plugin;

/+
class ModbusModule : Plugin
{
	enum string PluginName = "modbus";

	this()
	{
		super(PluginName);
	}

	override Instance initInstance(ApplicationInstance instance)
	{
		return new Instance(this, instance);
	}

	class Instance : Plugin.Instance
	{
		ModbusModule plugin;

		this(ModbusModule plugin, ApplicationInstance instance)
		{
			super(instance);
			this.plugin = plugin;

//			instance.console.registerCommands("/protocol/modbus", [
//				new LogCommand(instance.console, "info", Category.Info, this),
//				new LogCommand(instance.console, "warn", Category.Warning, this),
//				new LogCommand(instance.console, "error", Category.Error, this),
//				new LogCommand(instance.console, "alert", Category.Alert, this),
//				new LogCommand(instance.console, "debug", Category.Debug, this)
//			]);
		}
	}
}


private:

shared static this()
{
	getGlobalInstance.registerPlugin(new ModbusModule);
}
+/
