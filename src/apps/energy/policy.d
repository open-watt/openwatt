module apps.energy.policy;

import urt.array;
import urt.conv : parse_float;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.si.unit : Celsius, Percent;
import urt.string;
import urt.time;
import urt.variant : Variant;

import apps.energy.appliance;
import apps.energy.control;
import apps.energy.model : read_in_unit;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.expression : Expression, EvalContext, parse_expression, free_expression;

nothrow @nogc:


enum PolicyTier : ubyte
{
    floor,
    essential,
    important,
    opportunistic,
}

enum PolicyShape : ubyte
{
    urgent,
    window,
}

enum GoalKind : ubyte
{
    none,
    on,
    off,
    soc,
    temp,
    duty,
    expression,
}

struct Goal
{
nothrow @nogc:
    GoalKind kind;
    float arg = 0;
    Duration arg_duration;
    Expression* expression;
}


class Policy : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("target", target),
                                 Prop!("tier", tier),
                                 Prop!("goal", goal),
                                 Prop!("deadline", deadline),
                                 Prop!("shape", shape));
nothrow @nogc:

    enum type_name = "policy";
    enum path = "/apps/energy/policy";
    enum collection_id = CollectionType.policy;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!Policy, id, flags);
    }

    // Resolve eagerly so allocator passes do not rescan the collection.
    const(char)[] target() const pure { return _target_name[]; }
    const(char)[] target(const(char)[] value)
    {
        if (value.length == 0)
            return "target is required";
        Appliance a = get_item_by_name!Appliance(value);
        if (a is null)
            return tconcat("appliance not found: ", value);
        _target_name = value.makeString(g_app.allocator);
        _target_appliance = a;
        mark_set!(typeof(this), "target")();
        restart();
        return null;
    }

    PolicyTier tier() const pure { return _tier; }
    void tier(PolicyTier value)
    {
        if (_tier == value)
            return;
        _tier = value;
        mark_set!(typeof(this), "tier")();
    }

    const(char)[] goal() const pure { return _goal_text[]; }
    const(char)[] goal(const(char)[] value)
    {
        Goal parsed;
        if (!parse_goal(value, parsed))
            return "invalid goal syntax; expected on, off, soc(N), temp(N), duty(Nh|Nm|Ns), or (expression)";
        if (_goal.expression)
            free_expression(_goal.expression);
        _goal_text = value.makeString(g_app.allocator);
        _goal = parsed;
        mark_set!(typeof(this), "goal")();
        restart();
        return null;
    }

    ~this()
    {
        if (_goal.expression)
            free_expression(_goal.expression);
    }

    TimeOfDay deadline() const pure { return _deadline; }
    void deadline(TimeOfDay value)
    {
        if (_deadline == value)
            return;
        _deadline = value;
        mark_set!(typeof(this), "deadline")();
    }

    PolicyShape shape() const pure { return _shape; }
    void shape(PolicyShape value)
    {
        if (_shape == value)
            return;
        _shape = value;
        mark_set!(typeof(this), "shape")();
    }

    ref const(Goal) parsed_goal() const pure { return _goal; }
    Appliance target_appliance() pure { return _target_appliance.get; }

protected:
    override bool validate() const
    {
        if (_target_appliance is null)
        {
            writeError("Policy '", name, "': no target");
            return false;
        }
        if (_goal.kind == GoalKind.none)
        {
            writeError("Policy '", name, "': no goal");
            return false;
        }
        if (_goal.kind == GoalKind.duty)
        {
            writeError("Policy '", name, "': duty goals are not yet supported (Control has no duty accumulator)");
            return false;
        }
        // Placeholder appliances may acquire a usable control later.
        return true;
    }

private:
    String _target_name;
    ObjectRef!Appliance _target_appliance;
    PolicyTier _tier;
    String _goal_text;
    Goal _goal;
    TimeOfDay _deadline;
    PolicyShape _shape = PolicyShape.urgent;
}


Element* witness_element(ref const Goal goal, const(Control)* ctl)
{
    if (ctl is null)
        return null;
    final switch (goal.kind) with (GoalKind)
    {
        case none:
            return null;
        case on:
        case off:
            if (ctl.enable_e !is null)
                return cast(Element*)ctl.enable_e;
            return cast(Element*)ctl.setpoint_e;
        case soc:
        case temp:
            return cast(Element*)ctl.state_e;
        case duty:
            return null;
        case expression:
            return null;
    }
}

// Goal arguments use display units, regardless of the witness's storage scale.
float current_value(Policy p, const(Control)* ctl)
{
    Element* e = witness_element(p.parsed_goal, ctl);
    if (e is null)
        return float.nan;
    if (e.value.isBool)
        return e.value.asBool ? 1.0f : 0.0f;
    if (!e.value.isNumber)
        return float.nan;
    switch (p.parsed_goal.kind) with (GoalKind)
    {
        case soc:  return read_in_unit(e, Percent);
        case temp: return read_in_unit(e, Celsius);
        default:   return cast(float)e.normalised_value();
    }
}

enum float soc_temp_deadband = 2.0f;

bool satisfied(Policy p, const(Control)* ctl)
{
    Element* e = witness_element(p.parsed_goal, ctl);
    final switch (p.parsed_goal.kind) with (GoalKind)
    {
        case none:
            return false;
        case on:
            if (e is null)
                return false;
            if (e.value.isBool)
                return e.value.asBool;
            if (!e.value.isNumber)
                return false;
            return e.normalised_value() > 0;
        case off:
            if (e is null)
                return false;
            if (e.value.isBool)
                return !e.value.asBool;
            if (!e.value.isNumber)
                return false;
            // A positive minimum still draws, so parking there cannot satisfy off.
            return e.normalised_value() <= 0;
        case soc:
        case temp:
            float cv = current_value(p, ctl);
            if (cv != cv)
                return false;
            bool driving = ctl !is null && ctl.current_setpoint == ctl.current_setpoint && ctl.current_setpoint > 0;
            return cv >= p.parsed_goal.arg + (driving ? soc_temp_deadband : 0);
        case duty:
            float cv = current_value(p, ctl);
            if (cv != cv)
                return false;
            return cv >= p.parsed_goal.arg_duration.as!"seconds";
        case expression:
            // TODO: decide whether non-boolean truthy expression results count.
            if (p.parsed_goal.expression is null || p.target_appliance is null)
                return false;
            // TODO: define an appliance-level expression context instead of using
            // the primary device.
            Component ctx_c = p.target_appliance.device_ref;
            if (ctx_c is null)
                return false;
            EvalContext ctx = { ctx_c, null, null };
            Variant v = p.parsed_goal.expression.evaluate(ctx);
            return v.isBool && v.asBool;
    }
}

void publish_policy(Device energy_device, Policy p, ControlRegistry registry)
{
    import urt.meta.enuminfo : enum_key_from_value;

    if (energy_device is null || p is null)
        return;

    Control* ctl = registry !is null ? registry.lookup(p.target_appliance) : null;

    const(char)[] base = tconcat("policy.", p.name[]);
    SysTime now = getSysTime();

    void set_text(string field, const(char)[] val)
    {
        energy_device.set_element(tconcat(base, ".", field), val, now);
    }
    void set_num(string field, float val)
    {
        energy_device.set_element(tconcat(base, ".", field), val, now);
    }
    void set_bool(string field, bool val)
    {
        energy_device.set_element(tconcat(base, ".", field), val, now);
    }

    set_text("target", p.target);
    set_text("tier", enum_key_from_value!PolicyTier(p.tier));
    set_text("goal", p.goal);

    GoalKind kind = p.parsed_goal.kind;
    if (kind == GoalKind.soc || kind == GoalKind.temp)
        set_num("goal_value", p.parsed_goal.arg);

    float cv = current_value(p, ctl);
    if (cv == cv)
        set_num("current_value", cv);

    set_bool("satisfied", satisfied(p, ctl));
}


bool parse_goal(const(char)[] text, out Goal goal)
{
    text = text.trim;
    if (text == "on")  { goal.kind = GoalKind.on;  return true; }
    if (text == "off") { goal.kind = GoalKind.off; return true; }

    if (text.length >= 2 && text[0] == '(' && text[$-1] == ')')
    {
        const(char)[] cursor = text[1 .. $-1].trim;
        Expression* expr;
        try
            expr = parse_expression(cursor);
        catch (Exception)
            return false;
        if (expr is null || cursor.length > 0)
        {
            if (expr)
                free_expression(expr);
            return false;
        }
        goal.kind = GoalKind.expression;
        goal.expression = expr;
        return true;
    }

    size_t paren = 0;
    while (paren < text.length && text[paren] != '(')
        ++paren;
    if (paren == 0 || paren == text.length || text[$-1] != ')')
        return false;

    const(char)[] name = text[0 .. paren];
    const(char)[] inner = text[paren + 1 .. $ - 1].trim;

    if (name == "soc")
        return parse_number(inner, GoalKind.soc, goal);
    if (name == "temp")
        return parse_number(inner, GoalKind.temp, goal);
    if (name == "duty")
        return parse_duty(inner, goal);
    return false;
}


private:

bool parse_number(const(char)[] text, GoalKind kind, out Goal goal)
{
    size_t consumed;
    double v = parse_float(text, &consumed);
    if (consumed == 0 || consumed != text.length)
        return false;
    goal.kind = kind;
    goal.arg = cast(float)v;
    return true;
}

bool parse_duty(const(char)[] text, out Goal goal)
{
    if (text.length == 0)
        return false;
    char suffix = text[$-1];
    if (suffix != 'h' && suffix != 'm' && suffix != 's')
        return false;
    size_t consumed;
    double v = parse_float(text[0 .. $-1], &consumed);
    if (consumed == 0 || consumed + 1 != text.length)
        return false;
    goal.kind = GoalKind.duty;
    goal.arg = cast(float)v;
    final switch (suffix)
    {
        case 'h': goal.arg_duration = dur!"hours"(cast(long)v); break;
        case 'm': goal.arg_duration = dur!"minutes"(cast(long)v); break;
        case 's': goal.arg_duration = dur!"seconds"(cast(long)v); break;
    }
    return true;
}
