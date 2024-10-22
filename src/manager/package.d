module manager;

import urt.array;
import urt.lifetime : move;
import urt.map;
import urt.mem.allocator;
import urt.string;

public import manager.instance;
import manager.plugin;


__gshared GlobalInstance globalInstance;


GlobalInstance getGlobalInstance() nothrow @nogc
{
	if (!globalInstance)
		globalInstance = defaultAllocator().allocT!GlobalInstance();
	return globalInstance;
}

class GlobalInstance
{
	Map!(String, ApplicationInstance) instances;
	Array!Plugin modules;

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

	Plugin getModule(const(char)[] name) nothrow @nogc
	{
		foreach (plugin; modules)
			if (plugin.moduleName[] == name[])
				return plugin;
		return null;
	}

	Module getModule(Module)() nothrow @nogc
	{
		return cast(Module)getModule(Module.ModuleName);
	}


	ApplicationInstance createInstance(String name) nothrow @nogc
	{
		ApplicationInstance app = defaultAllocator().allocT!ApplicationInstance();
		app.name = name.move;
		app.global = getGlobalInstance();

		instances[name] = app;

		app.pluginInstance.resize(modules.length);
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
