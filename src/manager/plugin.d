module manager.plugin;

import manager;
import manager.config : ConfItem;

class Plugin
{
	string name;
	size_t id = -1;

	this(string name)
	{
		this.name = name;
	}

	void init(GlobalInstance global)
	{
	}

	Instance initInstance(ApplicationInstance instance)
	{
		return null;
	}

	class Instance
	{
		ApplicationInstance app;
//		alias app = this;

		this(ApplicationInstance app)
		{
			this.app = app;
		}

		void parseConfig(ref ConfItem conf)
		{
		}

		void preUpdate()
		{
		}

		void postUpdate()
		{
		}
	}


	void preUpdate(GlobalInstance global)
	{
	}

	void postUpdate(GlobalInstance global)
	{
	}
}
