module apps.energy.policy;

import urt.array;
import urt.conv : parse_float;
import urt.lifetime;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.variant : Variant;

import apps.energy.appliance;
import apps.energy.control;

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

    // target  - name of an Appliance. Resolved eagerly to a class reference so
    // the planner/allocator can look up a Control via the registry without
    // re-walking the appliance collection each call.
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
        restart();
        return null;
    }

    PolicyTier tier() const pure { return _tier; }
    void tier(PolicyTier value)
    {
        if (_tier == value)
            return;
        _tier = value;
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
    }

    PolicyShape shape() const pure { return _shape; }
    void shape(PolicyShape value)
    {
        if (_shape == value)
            return;
        _shape = value;
    }

    ref const(Goal) parsed_goal() const pure { return _goal; }
    Appliance target_appliance() pure { return _target_appliance; }

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
        // NOTE: we don't validate that the target *can* satisfy the goal kind
        // here  - the appliance's Control may not yet exist (placeholder/unconnected
        // car). satisfied() returns false at runtime when the witness is missing.
        return true;
    }

    override CompletionStatus startup()
    {
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.complete;
    }

    override void update()
    {
    }

private:
    String _target_name;
    Appliance _target_appliance;
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
            // Prefer the explicit enable element (composite case: car BLE
            // charging flag); fall back to setpoint for simple Switch-shaped
            // controls where enable_e and setpoint are the same element.
            if (ctl.enable_e !is null)
                return cast(Element*)ctl.enable_e;
            return cast(Element*)ctl.setpoint;
        case soc:
        case temp:
            return cast(Element*)ctl.state_e;
        case duty:
            // TODO: Control has no accumulated_duty slot. Add one to the synth
            //       pipeline when an appliance uses duty goals; for now this
            //       always returns null and duty goals never satisfy.
            return null;
        case expression:
            return null;
    }
}

float current_value(Policy p, const(Control)* ctl)
{
    Element* e = witness_element(p.parsed_goal, ctl);
    if (e is null)
        return float.nan;
    if (e.value.isBool)
        return e.value.asBool ? 1.0f : 0.0f;
    if (e.value.isNumber)
        return e.value.asFloat;
    return float.nan;
}

bool satisfied(Policy p, const(Control)* ctl)
{
    Element* e = witness_element(p.parsed_goal, ctl);
    final switch (p.parsed_goal.kind) with (GoalKind)
    {
        case none:
            return false;
        case on:
            return e !is null && e.value.isBool && e.value.asBool;
        case off:
            return e !is null && e.value.isBool && !e.value.asBool;
        case soc:
        case temp:
            float cv = current_value(p, ctl);
            return cv == cv && cv >= p.parsed_goal.arg;
        case duty:
            float cv = current_value(p, ctl);
            if (cv != cv)
                return false;
            return cv >= p.parsed_goal.arg_duration.as!"seconds";
        case expression:
            // TODO: only true-bool means satisfied right now. Numeric/string truthy
            //       expressions (e.g. `@temp > 60` returns bool, but `@temp` alone returns
            //       a number) should arguably count too. Tighten when we have real cases.
            if (p.parsed_goal.expression is null || p.target_appliance is null)
                return false;
            // Expression evaluation runs against the appliance's primary device,
            // since expression goals were originally written assuming a Component
            // target. TODO: redesign expression-goal contract to operate on
            // appliance-level state (e.g. summed power, graph-derived SOC) rather than
            // a single Component.
            Component ctx_c = p.target_appliance.device_ref;
            if (ctx_c is null)
                return false;
            EvalContext ctx = { ctx_c, null, null };
            Variant v = p.parsed_goal.expression.evaluate(ctx);
            return v.isBool && v.asBool;
    }
}

// Marginal value is set by analyse_policy in planner.d (slack-aware). This
// retains a coarse fallback for direct callers (kept tier-only; no slack).
float marginal_value(Policy p, const(Control)* ctl)
{
    final switch (p.tier) with (PolicyTier)
    {
        case floor:
            return satisfied(p, ctl) ? 0.0f : float.infinity;
        case essential:
            return satisfied(p, ctl) ? 0.0f : 0.8f;
        case important:
            return satisfied(p, ctl) ? 0.0f : 0.5f;
        case opportunistic:
            return satisfied(p, ctl) ? 0.0f : 0.2f;
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
        if (Element* e = energy_device.find_or_create_element(tconcat(base, ".", field)))
            e.value(val, now);
    }
    void set_num(string field, float val)
    {
        if (Element* e = energy_device.find_or_create_element(tconcat(base, ".", field)))
            e.value(val, now);
    }
    void set_bool(string field, bool val)
    {
        if (Element* e = energy_device.find_or_create_element(tconcat(base, ".", field)))
            e.value(val, now);
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
    set_num("marginal_value", marginal_value(p, ctl));
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
