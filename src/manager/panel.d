module manager.panel;

import urt.file : delete_file;
import urt.log;
import urt.meta.nullable;
import urt.string.format : FormatArg;
import urt.time;

import manager;
import manager.config_revision : erase_config_revisions;
import manager.component;
import manager.console.session;
import manager.device;
import manager.element;
import manager.plugin;
import manager.saved_config : saved_config_file;
import manager.secret : secret_store_file;
import manager.sync.peering : fleet_id_file;

import driver.system : system_reboot;

nothrow @nogc:


enum ButtonEvent : ubyte
{
    click,
    double_,
    triple,
    hold,
    release,
}

enum LightEffect : ubyte
{
    none,
    blink,
    fast_blink,
    breathe,
    flash,
    rainbow,
}

// sRGB, written #rrggbb
struct Colour
{
nothrow @nogc:
    ubyte r, g, b;

    uint rgb() const pure
        => r << 16 | g << 8 | b;

    ptrdiff_t toString(char[] buffer, const(char)[], const(FormatArg)[]) const pure
    {
        if (!buffer.ptr)
            return 7;
        if (buffer.length < 7)
            return -1;
        static immutable char[16] digits = "0123456789abcdef";
        buffer[0] = '#';
        foreach (i; 0 .. 6)
            buffer[1 + i] = digits[rgb >> (20 - i * 4) & 0xF];
        return 7;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        size_t start = s.length && s[0] == '#';
        if (s.length < start + 6)
            return -1;
        uint v;
        foreach (c; s[start .. start + 6])
        {
            uint d = c >= '0' && c <= '9' ? c - '0' : (c | 0x20) >= 'a' && (c | 0x20) <= 'f' ? (c | 0x20) - 'a' + 10 : 16;
            if (d == 16)
                return -1;
            v = v << 4 | d;
        }
        r = cast(ubyte)(v >> 16);
        g = cast(ubyte)(v >> 8);
        b = cast(ubyte)v;
        return start + 6;
    }
}

// ascending precedence: the highest live gesture is the one expressed
enum Gesture : ubyte
{
    booting,
    identify,
    upgrading,
    reset_armed,
}

struct Indication
{
    ubyte slot = ubyte.max;
    ubyte generation;
}

Indication indicate(Gesture gesture, Duration duration = Duration.max)
    => g_panel.start(gesture, duration);

void end_indication(ref Indication indication)
{
    g_panel.end(indication);
    indication = Indication();
}

bool indicating(ref const Indication indication)
    => g_panel.live(indication);


final class PanelModule : Module
{
    mixin DeclareModule!"panel";
nothrow @nogc:

    override void init()
    {
        g_panel = this;
        register_element_lifecycle_handler(&element_lifecycle);
        g_app.console.register_command!identify("/system", this);
    }

    void identify(Session session, Nullable!Duration duration)
    {
        indicate(Gesture.identify, duration ? duration.value : 10.seconds);
    }

private:
    enum armed_window = 15.seconds;

    struct Expression
    {
        LightEffect effect;
        Colour colour;
    }

    static immutable Expression[Gesture.max + 1] expression = [
        Expression(LightEffect.breathe, Colour(0, 0, 255)),
        Expression(LightEffect.flash, Colour(255, 255, 255)),
        Expression(LightEffect.blink, Colour(0, 255, 255)),
        Expression(LightEffect.fast_blink, Colour(255, 0, 0)),
    ];
    static immutable running = Colour(0, 255, 0);

    struct Slot
    {
        MonoTime until;     // init: until ended
        Gesture gesture;
        ubyte generation;
        bool live;
    }

    Slot[8] _slots;
    Element* _status;
    Element* _status_colour;
    Indication _armed;

    Indication start(Gesture gesture, Duration duration)
    {
        foreach (i, ref s; _slots)
        {
            if (s.live)
                continue;
            s.gesture = gesture;
            s.until = duration == Duration.max ? MonoTime() : getTime() + duration;
            s.live = true;
            ++s.generation;
            changed();
            return Indication(cast(ubyte)i, s.generation);
        }
        log_warning("panel", "no slot for gesture ", gesture);
        return Indication();
    }

    void end(ref const Indication indication)
    {
        if (!live(indication))
            return;
        _slots[indication.slot].live = false;
        changed();
    }

    bool live(ref const Indication indication) const
        => indication.slot < _slots.length && _slots[indication.slot].live && _slots[indication.slot].generation == indication.generation;

    void expire(MonoTime now)
    {
        foreach (ref s; _slots)
        {
            if (s.live && s.until != MonoTime() && s.until <= now)
                s.live = false;
        }
        changed();
    }

    void changed()
    {
        g_app.cancel(&expire);
        MonoTime next;
        bool any;
        Gesture shown;
        foreach (ref s; _slots)
        {
            if (!s.live)
                continue;
            if (!any || s.gesture > shown)
                shown = s.gesture;
            any = true;
            if (s.until != MonoTime() && (next == MonoTime() || s.until < next))
                next = s.until;
        }
        if (next != MonoTime())
            g_app.schedule(next, &expire);
        if (_status_colour && any)
        {
            Colour colour = expression[shown].colour;
            _status_colour.value(colour);
        }
        if (_status)
            _status.value(any ? expression[shown].effect : LightEffect.none);
    }

    void element_lifecycle(Element* e, ElementLifecycleEvent event)
    {
        if (event == ElementLifecycleEvent.destroyed)
        {
            if (e is _status)
                _status = null;
            if (e is _status_colour)
                _status_colour = null;
            return;
        }
        Device owner = e.parent ? e.parent.root_device() : null;
        if (!owner || !g_app.devices.node || owner.peer_id != g_app.devices.node)
            return;
        char[64] buf = void;
        ptrdiff_t len = e.full_path(buf);
        if (len <= 0 || len > buf.length)
            return;
        const(char)[] path = buf[0 .. len];
        if (path == "system.panel.status.switch")
            e.value(true);
        else if (path == "system.panel.status.colour")
        {
            Colour colour = running;
            e.value(colour);
        }
        else if (path == "system.panel.status.indicate_colour")
        {
            _status_colour = e;
            changed();
        }
        else if (path == "system.panel.status.indicate")
        {
            _status = e;
            changed();
        }
        else if (path == "system.panel.reset.event")
            e.subscribe(&reset_event);
    }

    // click reboots; a hold arms a factory reset that the release carries out, unless the armed window lapses first
    void reset_event(ref const SampleUpdate update)
    {
        if (!update.value_ready)
            return;
        switch (cast(ButtonEvent)update.value.asLong)
        {
            case ButtonEvent.click:
                log_notice("panel", "reset button: reboot");
                system_reboot();
                break;
            case ButtonEvent.hold:
                _armed = indicate(Gesture.reset_armed, armed_window);
                break;
            case ButtonEvent.release:
                if (indicating(_armed))
                    factory_reset();
                break;
            default:
                break;
        }
    }

    void factory_reset()
    {
        log_notice("panel", "reset button: factory reset");
        erase_config_revisions(saved_config_file);
        delete_file(secret_store_file);
        delete_file(fleet_id_file);
        system_reboot();
    }
}


private:

__gshared PanelModule g_panel;
