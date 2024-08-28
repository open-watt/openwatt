module manager;

import urt.mem.allocator;

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
	Plugin[] modules;

	import router.modbus.profile;

	void registerPlugin(Plugin plugin)
	{
		import urt.string.format;

		foreach (p; modules)
			assert(p.moduleName[] != plugin.moduleName, tconcat("Module '", plugin.moduleName, "' already registered"));

		plugin.moduleId = modules.length;
		modules ~= plugin;

		plugin.init();

		foreach (app; instances)
		{
			Plugin.Instance pluginInstance = plugin.createInstance(app);
			app.pluginInstance ~= pluginInstance;
		}
	}

	Plugin getModule(const(char)[] name)
	{
		foreach (plugin; modules)
			if (plugin.moduleName[] == name[])
				return plugin;
		return null;
	}

	Module getModule(Module)()
	{
		return cast(Module)getModule(Module.ModuleName);
	}


	ApplicationInstance createInstance(string name)
	{
		ApplicationInstance app = new ApplicationInstance();
		app.name = name;
		app.global = getGlobalInstance();

		instances[name] = app;

		app.pluginInstance = new Plugin.Instance[modules.length];
		foreach (i; 0 .. modules.length)
		{
			Plugin.Instance pluginInstance = modules[i].createInstance(app);
			app.pluginInstance[i] = pluginInstance;
		}

		return app;
	}

	void update()
	{
		foreach (plugin; modules)
			plugin.preUpdate();

		foreach(app; instances)
		{
			app.update();
		}

		foreach (plugin; modules)
			plugin.postUpdate();
	}
}
