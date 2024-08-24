module manager.plugin;

import manager;
import manager.config : ConfItem;


class Plugin
{
	GlobalInstance global;
	string moduleName;
	size_t moduleId = -1;

	this(GlobalInstance global, string name)
	{
		this.global = global;
		this.moduleName = name;
	}

	void init()
	{
	}

	void preUpdate()
	{
	}

	void postUpdate()
	{
	}

	abstract Instance createInstance(ApplicationInstance instance);

	class Instance
	{
		ApplicationInstance app;
//		alias app = this;

		this(ApplicationInstance app)
		{
			this.app = app;
		}

		void init()
		{
		}

		void parseConfig(ref ConfItem conf)
		{
		}

		void preUpdate()
		{
		}

		void update()
		{
		}

		void postUpdate()
		{
		}
	}
}

// helper template to register a plugin
mixin template RegisterModule(string name)
{
	import manager : GlobalInstance, ApplicationInstance;

	enum string ModuleName = name;
	alias ThisClass = __traits(parent, ModuleName);

	shared static this()
	{
		import manager : getGlobalInstance;
		getGlobalInstance.registerPlugin(new ThisClass(getGlobalInstance()));
	}

	this(GlobalInstance global)
	{
		super(global, ModuleName);
	}

	override Instance createInstance(ApplicationInstance instance)
	{
		return new Instance(instance);
	}
}

mixin template DeclareInstance()
{
//	ThisClass outer() inout pure nothrow @nogc { return cast(ThisClass)this.outer; }

	this(ApplicationInstance instance)
	{
		super(instance);

		init();
	}
}
