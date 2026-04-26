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

    override void init()
    {
        g_app.console.register_collection!CronJob();
    }

    override void update()
    {
        Collection!CronJob().update_all();
    }
}
