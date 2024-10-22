module manager.plugin;

import urt.string;

import manager;
import manager.config : ConfItem;


class Plugin
{
nothrow @nogc:

	GlobalInstance global;
	String moduleName;
	size_t moduleId = -1;

	this(GlobalInstance global, String name)
	{
		import urt.lifetime : move;

		this.global = global;
		this.moduleName = name.move;
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
	nothrow @nogc:

		ApplicationInstance app;
//		alias app = this;

		this(ApplicationInstance app)
		{
			this.app = app;
		}

		void init()
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

	this(GlobalInstance global) nothrow @nogc
	{
		super(global, StringLit!ModuleName);
	}

	override Instance createInstance(ApplicationInstance instance) nothrow @nogc
	{
		// we must do a @nogc thunk, because language has no way to express initialisation of a class with outer pointer...
		return (cast(Instance delegate(ApplicationInstance) nothrow @nogc)&createInstanceImpl)(instance);
	}

private:
    Instance createInstanceImpl(ApplicationInstance instance) nothrow
    {
        return new Instance(instance);
    }
}

mixin template DeclareInstance()
{
//	ThisClass outer() inout pure nothrow @nogc { return cast(ThisClass)this.outer; }

	this(ApplicationInstance instance) nothrow
	{
		super(instance);

		try
			init();
		catch(Exception e)
			assert(false);
	}
}
