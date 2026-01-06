module manager.cron;

import manager.collection;
import manager.console;
import manager.plugin;
import manager.cron.job;
import urt.string;

nothrow @nogc:


class CronModule : Module
{
    mixin DeclareModule!"cron";
nothrow @nogc:

    Collection!CronJob jobs;

    override void init()
    {
        g_app.console.register_collection("/system/cron", jobs);
    }

    override void update()
    {
        jobs.update_all();
    }
}
