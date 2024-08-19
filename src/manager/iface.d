module manager.iface;

import urt.string;

import manager;
import manager.console;
import manager.console.command;
import manager.console.session;
import manager.plugin;


class InterfaceModule : Plugin
{
	enum string PluginName = "interface";

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
		InterfaceModule plugin;

		this(InterfaceModule plugin, ApplicationInstance instance)
		{
			super(instance);
			this.plugin = plugin;

//			instance.console.registerCommands("/interface", [
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
	getGlobalInstance.registerPlugin(new InterfaceModule);
}
/+
class InterfaceCommand : Command
{
	InterfaceModule.Instance instance;

	this(ref Console console, const(char)[] name, InterfaceModule.Instance instance)
	{
		import urt.mem.string;

		super(console, String(name.addString));
		this.instance = instance;
	}

	override CommandState execute(Session session, const(char)[] cmdLine)
	{
		import manager.console.expression;

		// no args... complain with help
		session.writeLine("/interface command expected arguments");
		return null;
	}

	version (ExcludeAutocomplete) {} else
	{
		override String complete(const(char)[] cmdLine) const
		{
			assert(false);
			return String(null);
		}


		override String[] suggest(const(char)[] cmdLine) const
		{
			return null;
		}
	}

	version (ExcludeHelpText) {} else
	{
		override const(char)[] help(const(char)[] args) const
		{
			assert(false);
			return String(null);
		}
	}
}
+/
