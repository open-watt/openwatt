module manager.cron;

import urt.string;
import urt.time;

import manager.base : ObjectFlags;
import manager.collection;
import manager.console;
import manager.expression : NamedArgument;
import manager.plugin;

public import manager.cron.job;

nothrow @nogc:


class CronModule : Module
{
    mixin DeclareModule!"cron";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!CronJob();
    }

    override void update()
    {
        Collection!CronJob().update_all();
    }

    CronJob schedule_oneshot(Duration delay, const(char)[] command, const(char)[] name = null)
    {
        return Collection!CronJob().create(name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary),
            NamedArgument("schedule", delay), NamedArgument("command", command), NamedArgument("repeat", false));
    }
}
