module manager.cron;

import urt.string;
import urt.time;

import manager.base : ObjectFlags;
import manager.collection;
import manager.console;
import manager.expression : NamedArgument, Script, make_script;
import manager.plugin;

public import manager.cron.job;

nothrow @nogc:


class CronModule : Module
{
    mixin DeclareModule!"cron";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!Weekday();

        g_app.console.register_collection!CronJob();
    }

    // Cron firing itself is timer-driven (CronJob.on_fire); this only
    // exists to keep state-machine transitions (validate → startup →
    // shutdown) ticking. Once BaseObject state changes become event-
    // driven, this can go away too.
    override void update()
    {
        Collection!CronJob().update_all();
    }

    CronJob schedule_oneshot(Duration delay, const(char)[] command, const(char)[] name = null)
    {
        Script body_ = make_script(command);
        return Collection!CronJob().create(name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
            NamedArgument("schedule", delay), NamedArgument("do", body_), NamedArgument("repeat", false));
    }
}
