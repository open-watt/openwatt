module manager.log;

import manager;
import manager.console;
import manager.console.command;
import manager.console.session;
import manager.config;
import manager.plugin;

import urt.log;
import urt.string;

enum Category
{
	Info,
	Warning,
	Error,
	Alert,
	Debug
}

class LogModule : Plugin
{
	enum string PluginName = "log";

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
		LogModule plugin;

		this(LogModule plugin, ApplicationInstance instance)
		{
			super(instance);
			this.plugin = plugin;

			instance.console.registerCommands("/log", [
				new LogCommand(instance.console, "info", Category.Info, this),
				new LogCommand(instance.console, "warn", Category.Warning, this),
				new LogCommand(instance.console, "error", Category.Error, this),
				new LogCommand(instance.console, "alert", Category.Alert, this),
				new LogCommand(instance.console, "debug", Category.Debug, this)
			]);
		}

		override void parseConfig(ref ConfItem conf)
		{
		}
	}
}


private:

shared static this()
{
	getGlobalInstance.registerPlugin(new LogModule);
}

class LogCommand : Command
{
	LogModule.Instance instance;
	Category category;

	this(ref Console console, const(char)[] name, Category category, LogModule.Instance instance)
	{
		import urt.mem.string;

		super(console, String(name.addString));
		this.instance = instance;
		this.category = category;
	}

	override CommandState execute(Session session, const(char)[] cmdLine)
	{
		import manager.console.expression;

		while (1)
		{
			cmdLine = cmdLine.trimCmdLine;

			if (cmdLine.empty)
				break;

			KVP t = cmdLine.takeKVP;
			if (t.k.type == Token.Type.Error)
			{
				session.writeLine(t.k.token);
				return null;
			}

			if (t.v.type != Token.Type.None)
			{
				// it's a kvp arg...
			}
			else
			{
				if (t.k.type != Token.Type.String)
				{
					session.writeLine("Invalid argument: /log command expected string argument");
					return null;
				}

				const(char)[] text = t.k.token.unQuote;

				final switch (category)
				{
					case Category.Info:
						writeInfo(text);
						break;
					case Category.Warning:
						writeWarning(text);
						break;
					case Category.Error:
						writeError(text);
						break;
					case Category.Alert:
						// TODO: implement ALERT type...
						writeError(text);
						break;
					case Category.Debug:
						writeDebug(text);
						break;
				}
				return null;
			}
		}

		// no args... complain with help
		session.writeLine("/log command expected string argument");
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
