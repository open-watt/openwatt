module manager.saved_config;

import urt.log;
import urt.meta.nullable;
import urt.result;
import urt.string;
import urt.variant : Variant;

import manager;
import manager.base;
import manager.collection;
import manager.config_revision;
import manager.console.session;

nothrow @nogc:


enum saved_config_file = "conf/config.conf";

void export_all(ref MutableString!0 buf)
{
    import manager.system : hostname, hostname_explicit;

    if (hostname_explicit)
    {
        buf.append("/system/set-hostname hostname=");
        Variant value = Variant(hostname[]);
        append_config_value(buf, value);
        buf.append('\n');
    }

    static immutable string[3] phase_names = [ "Create", "Configure", "Enable" ];
    foreach (phase; 0 .. 3)
    {
        buf.append("\n# ", phase_names[phase], "\n");
        foreach (ref t; g_app.types.values)
        {
            if (!t.type_info.create)
                continue;
            foreach (obj; BaseCollection(t.type_info).values)
            {
                if (obj._typeInfo !is t.type_info || obj.flags & (ObjectFlags.dynamic | ObjectFlags.temporary) || obj._is_remote)
                    continue;
                final switch (phase)
                {
                    case 0:
                        buf.append(t.path, "/add name=", obj.name[], " disabled=true\n");
                        break;
                    case 1:
                        obj.export_config(buf, t.path);
                        break;
                    case 2:
                        if (!obj.disabled)
                            buf.append(t.path, "/set ", obj.name[], " disabled=false\n");
                        break;
                }
            }
        }
    }
}

void config_export(Session session)
{
    MutableString!0 buf;
    export_all(buf);
    session.write(buf[]);
}

void config_save(Session session, Nullable!(const(char)[]) file)
{
    MutableString!0 buf;
    export_all(buf);

    const(char)[] path = file ? file.value : saved_config_file;
    int revision;
    import manager.secret : flush_secret_store;
    if (!valid_saved_config(buf[]))
    {
        session.write_line("configuration export is invalid; previous revision retained");
        return;
    }
    Result r = flush_secret_store();
    if (!r)
    {
        session.write_line("secret store could not be saved; previous configuration revision retained");
        return;
    }
    r = save_config_revision(path, buf[], revision);
    if (r)
    {
        if (path == saved_config_file)
            g_app.config_dirty = false;
        session.write_line("saved configuration revision ", revision, " to '", path, '.', revision, "' (", buf.length, " bytes)");
    }
    else
        session.write_line("failed to save configuration to '", path, "'");
}


bool valid_saved_config(const(char)[] source)
{
    import manager.expression : parse_commands, free_script_command;
    const(char)[] error;
    auto commands = parse_commands(source, error);
    foreach (ref command; commands[])
        free_script_command(command);
    if (error)
        log_warning("config", "saved config failed to parse: ", error);
    return error is null;
}
