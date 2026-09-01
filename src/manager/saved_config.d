module manager.saved_config;

import urt.file : load_file, save_file;
import urt.mem;
import urt.meta.nullable;
import urt.result;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.console.session;

nothrow @nogc:


enum saved_config_file = "conf/config.conf";

// emit add commands which recreate every explicitly-configured object
void export_all(ref MutableString!0 buf)
{
    foreach (ref type_name; g_app.type_order)
    {
        auto t = type_name in g_app.types;
        if (!t || !t.type_info.create)
            continue;

        bool any = false;
        BaseCollection collection = BaseCollection(t.type_info);
        foreach (obj; collection.values)
        {
            if (obj._typeInfo !is t.type_info)
                continue;
            if (obj.flags & (ObjectFlags.dynamic | ObjectFlags.temporary))
                continue;
            if (obj._is_remote)
                continue;
            if (!any)
            {
                if (buf.length > 0)
                    buf.append('\n');
                any = true;
            }
            obj.export_config(buf, t.path);
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
    Result r = save_file(path, cast(const(void)[])buf[]);
    if (r)
    {
        if (path == saved_config_file)
            g_app.config_dirty = false;
        session.write_line("saved configuration to '", path, "' (", buf.length, " bytes)");
    }
    else
        session.write_line("failed to save configuration to '", path, "'");
}
