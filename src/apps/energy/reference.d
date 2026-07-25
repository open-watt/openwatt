module apps.energy.reference;

import urt.string;

import manager;
import manager.component;
import manager.device;

nothrow @nogc:


Component resolve_component_path(const(char)[] path)
{
    size_t dot = path.findFirst('.');
    const(char)[] device_id = path[0 .. dot];
    Device* d = device_id in g_app.devices;
    if (!d)
        return null;
    if (dot == path.length)
        return *d;
    return (*d).find_component(path[dot + 1 .. $]);
}
