module apps.automation;

import urt.mem.temp : tconcat;
import urt.time;

import manager.base : ObjectFlags;
import manager.collection;
import manager.console;
import manager.expression : NamedArgument, Script, make_script;
import manager.plugin;

public import apps.automation.automation;

nothrow @nogc:


class AutomationModule : Module
{
    mixin DeclareModule!"automation";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!Automation();
    }

    override void update()
    {
        Collection!Automation().update_all();
    }

    Automation schedule_oneshot(Duration delay, const(char)[] command, const(char)[] name = null)
    {
        Script body_ = make_script(command);
        return Collection!Automation().create(name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
            NamedArgument("on", tconcat("every:", delay, "?repeat=false")), NamedArgument("do", body_));
    }
}
