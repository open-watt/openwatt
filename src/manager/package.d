module manager;

public import manager.instance;
import manager.plugin;


__gshared GlobalInstance globalInstance;


GlobalInstance getGlobalInstance()
{
	if (!globalInstance)
		globalInstance = new GlobalInstance();
	return globalInstance;
}

class GlobalInstance
{
	ApplicationInstance[string] instances;
	Plugin[] plugins;

	import router.modbus.profile;

	void registerPlugin(Plugin plugin)
	{
		foreach (p; plugins)
			assert(p.name[] != plugin.name);

		plugin.id = plugins.length;
		plugins ~= plugin;

		plugin.init(this);

		foreach (app; instances)
		{
			Plugin.Instance pluginInstance = plugin.initInstance(app);
			app.pluginInstance ~= pluginInstance;
		}
	}

	Plugin getPlugin(const(char)[] name)
	{
		foreach (plugin; plugins)
			if (plugin.name[] == name[])
				return plugin;
		return null;
	}

	ApplicationInstance createInstance(string name)
	{
		ApplicationInstance app = new ApplicationInstance();
		app.name = name;
		app.global = getGlobalInstance();

		instances[name] = app;

		app.pluginInstance = new Plugin.Instance[plugins.length];
		foreach (i; 0 .. plugins.length)
		{
			Plugin.Instance pluginInstance = plugins[i].initInstance(app);
			app.pluginInstance[i] = pluginInstance;
		}

		return app;
	}

	void update()
	{
		foreach (plugin; plugins)
			plugin.preUpdate(this);

		foreach(app; instances)
		{
			app.update();
		}

		foreach (plugin; plugins)
			plugin.postUpdate(this);
	}
}
