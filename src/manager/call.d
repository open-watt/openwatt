module manager.call;

import urt.array;
import urt.hash : fnv1a;
import urt.lifetime : move;
import urt.mem.allocator : defaultAllocator;
import urt.mem.string;
import urt.mem.temp : tconcat;
import urt.meta;
import urt.meta.nullable;
import urt.meta.tuple;
import urt.result : StringResult;
import urt.string;
import urt.traits;
import urt.variant;

import manager.expression : NamedArgument;
import manager.value : from_variant, to_variant;


char[] transform_function_name(const(char)[] name)
{
    assert(__ctfe, "Should only be used at compile time");

    name = name.length > 0 && name[0] == '_' ? name[1 .. $] : name;
    char[] result = name.dup;
    foreach (i, c; result)
        if (c == '_')
            result[i] = '-';
    return result;
}
enum TransformFunctionName(const(char)[] name) = transform_function_name(name);

nothrow @nogc:


alias SuggestFunction = Array!String function(const(char)[] value) nothrow @nogc;
alias CustomSuggestFunction = Array!String function(bool is_value, const(char)[] name,
                                                    const(char)[] value) nothrow @nogc;

struct TabComplete
{
    CustomSuggestFunction suggest;
}

enum ParameterFlags : ubyte
{
    none = 0,
    optional = 1 << 0,
    ref_ = 1 << 1,
    out_ = 1 << 2,
    lazy_ = 1 << 3,
    positional_rest = 1 << 4,
    named_rest = 1 << 5,
}

struct CallTypeId
{
    uint value;
}

struct SignatureId
{
    uint value;
}

struct ParameterInfo
{
    String name;
    CallTypeId type;
    ParameterFlags flags;
    version (ExcludeHelpText) {} else
        String type_name;
    SuggestFunction suggest;
}

class CallState
{
nothrow @nogc:
}

struct CallContext
{
    Object caller;
}

struct CallResult
{
    Variant value;
    CallState state;
    const(char)[] error;
    bool has_value;
}

alias GenericEntry = CallResult function(
    void* target,
    ref CallContext context,
    const Variant[] arguments,
    const NamedArgument[] named_arguments) nothrow @nogc;

private alias RawEntry = void function() nothrow @nogc;
private alias HardAdapter = CallResult function(
    void* target,
    RawEntry entry,
    ref CallContext context,
    const Variant[] arguments,
    const NamedArgument[] named_arguments) nothrow @nogc;

struct FunctionInfo
{
    SignatureId signature;
    CallTypeId result;
    Array!ParameterInfo parameters;
    HardAdapter call_hard;
    CustomSuggestFunction custom_suggest;
}

struct Function
{
nothrow @nogc:

    const(FunctionInfo)* info;

    static Function create(alias fun, Instance, alias suggest)(Instance instance)
        if (is_some_function!fun)
    {
        return create_hard!(fun, Instance, suggest, 0, false)(instance);
    }

    static Function create_contextual(alias fun, Instance, alias suggest)(Instance instance)
        if (is_some_function!fun)
    {
        static assert(Parameters!fun.length != 0,
                      "a contextual function needs a caller parameter");
        static assert(is(Parameters!fun[0] : Object),
                      "the contextual function's first parameter must be a class");
        return create_hard!(fun, Instance, suggest, 1, true)(instance);
    }

    static Function create_generic(R, Args...)(void* target, GenericEntry entry)
    {
        FunctionInfo* info = defaultAllocator().allocT!FunctionInfo();
        info.signature = signature_id!(R, Args);
        info.result = call_type_id!R;
        static foreach (Arg; Args)
            info.parameters ~= ParameterInfo(type: call_type_id!Arg);

        Function function_;
        function_.info = info;
        function_._target = tag(target);
        function_._entry = cast(RawEntry)entry;
        return function_;
    }

    CallResult call(ref CallContext context, const Variant[] arguments,
                    const NamedArgument[] named_arguments = null)
    {
        if (generic)
        {
            GenericEntry entry = cast(GenericEntry)_entry;
            return entry(untag(_target), context, arguments, named_arguments);
        }
        return info.call_hard(untag(_target), _entry, context, arguments, named_arguments);
    }

    StringResult call(R, Args...)(ref CallContext context, out R result, Args arguments)
    {
        if (!info || info.signature != signature_id!(R, Args))
            return StringResult("function signature mismatch");

        if (!generic)
        {
            alias Entry = R function(void*, ref CallContext, Args) nothrow @nogc;
            Entry entry = cast(Entry)_entry;
            result = entry(untag(_target), context, arguments);
            return StringResult.success;
        }

        Variant[Args.length] boxed;
        static foreach (i; 0 .. Args.length)
            boxed[i] = to_variant(arguments[i]);

        CallResult call_result = call(context, boxed[]);
        if (call_result.error)
            return StringResult(call_result.error);
        if (call_result.state)
            return StringResult("function call is pending");
        if (!call_result.has_value)
            return StringResult("function returned no value");
        return StringResult(from_variant(call_result.value, result));
    }

private:
    enum size_t generic_tag = 1;

    void* _target;
    RawEntry _entry;

    bool generic() const pure
        => (cast(size_t)_target & generic_tag) != 0;

    static void* tag(void* target) pure
    {
        assert((cast(size_t)target & generic_tag) == 0,
               "function target is not suitably aligned");
        return cast(void*)(cast(size_t)target | generic_tag);
    }

    static void* untag(void* target) pure
        => cast(void*)(cast(size_t)target & ~generic_tag);

    static Function create_hard(alias fun, Instance, alias suggest,
                                size_t skip, bool contextual)(Instance instance)
    {
        alias Return = ReturnType!fun;
        alias PublicParameters = Parameters!fun[skip .. $];
        alias StoredParameters = STATIC_MAP!(Unqual, PublicParameters);
        alias AllParameterNames = parameter_identifier_tuple!fun;
        alias PublicParameterNames = STATIC_MAP!(
            TransformFunctionName, AllParameterNames[skip .. $]);

        static Return hard_entry(void* target, ref CallContext context,
                                 StoredParameters arguments)
        {
            static if (contextual)
                auto caller = cast(Parameters!fun[0])context.caller;

            static if (is(__traits(parent, fun)))
            {
                alias Parent = __traits(parent, fun);
                auto object_ = cast(Parent)target;
                static if (is(Return == void))
                {
                    static if (contextual)
                        __traits(getMember, object_, __traits(identifier, fun))(caller, arguments);
                    else
                        __traits(getMember, object_, __traits(identifier, fun))(arguments);
                }
                else
                {
                    static if (contextual)
                        return __traits(getMember, object_, __traits(identifier, fun))(caller, arguments);
                    else
                        return __traits(getMember, object_, __traits(identifier, fun))(arguments);
                }
            }
            else
            {
                static if (is(Return == void))
                {
                    static if (contextual)
                        fun(caller, arguments);
                    else
                        fun(arguments);
                }
                else
                {
                    static if (contextual)
                        return fun(caller, arguments);
                    else
                        return fun(arguments);
                }
            }
        }

        static CallResult call_hard(void* target, RawEntry raw_entry,
                                    ref CallContext context,
                                    const Variant[] arguments,
                                    const NamedArgument[] named_arguments)
        {
            CallResult result;
            auto converted = make_argument_tuple!(fun, skip, !contextual)(
                arguments, named_arguments, result.error);
            if (result.error)
                return result;

            alias Entry = Return function(void*, ref CallContext,
                                          StoredParameters) nothrow @nogc;
            Entry entry = cast(Entry)raw_entry;
            static if (is(Return == void))
                entry(target, context, converted.expand);
            else static if (is(Return : CallState))
                result.state = entry(target, context, converted.expand);
            else
            {
                auto value = entry(target, context, converted.expand);
                result.value = to_variant(value);
                result.has_value = true;
            }
            return result;
        }

        FunctionInfo* info = defaultAllocator().allocT!FunctionInfo();
        info.signature = function_signature_id!(fun, skip);
        info.result = call_type_id!Return;
        info.call_hard = &call_hard;

        static foreach (i, Parameter; PublicParameters)
        {{
            ParameterInfo parameter;
            parameter.name = StringLit!(PublicParameterNames[i]);
            parameter.type = call_type_id!Parameter;
            parameter.flags = parameter_flags!(fun, i + skip);
            static if (PublicParameterNames[i] == "args")
                parameter.flags |= ParameterFlags.positional_rest;
            else static if (PublicParameterNames[i] == "named-args")
                parameter.flags |= ParameterFlags.named_rest;

            static if (is(Unqual!Parameter == Nullable!Value, Value))
            {
                alias ArgumentType = Value;
                parameter.flags |= ParameterFlags.optional;
            }
            else
                alias ArgumentType = Unqual!Parameter;

            version (ExcludeHelpText) {}
            else
                parameter.type_name = StringLit!(ArgumentType.stringof);

            static if (is(typeof(&suggest!ArgumentType)))
                parameter.suggest = &suggest!ArgumentType;
            info.parameters ~= parameter.move;
        }}

        static foreach (attribute; __traits(getAttributes, fun))
            static if (is(typeof(attribute) == TabComplete))
                info.custom_suggest = attribute.suggest;

        Function function_;
        function_.info = info;
        function_._target = cast(void*)instance;
        assert((cast(size_t)function_._target & generic_tag) == 0,
               "function target is not suitably aligned");
        function_._entry = cast(RawEntry)&hard_entry;
        return function_;
    }
}

template call_type_id(T)
{
    enum call_type_id = CallTypeId(fnv1a(cast(const(ubyte)[])T.stringof));
}

template signature_id(R, Args...)
{
    enum signature_id = SignatureId(calculate_signature_id!(R, Args));
}

template function_signature_id(alias fun, size_t skip = 0)
{
    enum function_signature_id = SignatureId(calculate_function_signature_id!(fun, skip));
}

private:

uint calculate_signature_id(R, Args...)()
{
    uint hash = fnv1a(cast(const(ubyte)[])R.stringof);
    static foreach (Arg; Args)
        hash = fnv1a(cast(const(ubyte)[])Arg.stringof, hash);
    return hash;
}

uint calculate_function_signature_id(alias fun, size_t skip)()
{
    uint hash = fnv1a(cast(const(ubyte)[])ReturnType!fun.stringof);
    static foreach (i, Parameter; Parameters!fun[skip .. $])
    {
        hash = fnv1a(cast(const(ubyte)[])Parameter.stringof, hash);
        static foreach (storage; __traits(getParameterStorageClasses, fun, i + skip))
            hash = fnv1a(cast(const(ubyte)[])storage, hash);
    }
    return hash;
}

template parameter_flags(alias fun, size_t index)
{
    enum parameter_flags = calculate_parameter_flags!(fun, index);
}

ParameterFlags calculate_parameter_flags(alias fun, size_t index)()
{
    ParameterFlags flags;
    static foreach (storage; __traits(getParameterStorageClasses, fun, index))
    {
        static if (storage == "ref")
            flags |= ParameterFlags.ref_;
        else static if (storage == "out")
            flags |= ParameterFlags.out_;
        else static if (storage == "lazy")
            flags |= ParameterFlags.lazy_;
    }
    return flags;
}

auto make_argument_tuple(alias fun, size_t skip, bool accept_positional)(
    const Variant[] arguments,
    const NamedArgument[] named_arguments,
    out const(char)[] error)
{
    alias Parameters_ = STATIC_MAP!(Unqual, Parameters!fun[skip .. $]);
    alias AllNames = parameter_identifier_tuple!fun;
    alias Names = STATIC_MAP!(TransformFunctionName, AllNames[skip .. $]);

    Tuple!Parameters_ parameters;
    bool[Parameters_.length] got_argument;
    bool has_arguments;
    bool has_named_arguments;
    error = null;

    static foreach (i, Parameter; Parameters_)
    {
        static if (Names[i] == "args")
            has_arguments = true;
        else static if (Names[i] == "named-args")
            has_named_arguments = true;
    }

    outer: foreach (ref named_argument; named_arguments)
    {
        parameter_switch: switch (named_argument.name)
        {
            static foreach (i, Parameter; Parameters_)
            {
                static if (Names[i] != "args" &&
                           Names[i] != "named-args")
                {
                    case Names[i]:
                        static if (is(const(Variant) : typeof(parameters[i])))
                            parameters[i] = named_argument.value;
                        else
                        {
                            error = from_variant(named_argument.value, parameters[i]);
                            if (error)
                            {
                                error = tconcat("Argument '", named_argument.name,
                                                "' error: ", error);
                                break outer;
                            }
                        }
                        got_argument[i] = true;
                        break parameter_switch;
                }
            }
            default:
                if (!has_named_arguments)
                {
                    error = tconcat("Unknown parameter '", named_argument.name, "'");
                    break outer;
                }
        }
    }

    static if (accept_positional)
    {
        size_t positional;
        static foreach (i, Parameter; Parameters_)
        {
            static if (Names[i] != "args" &&
                       Names[i] != "named-args")
            {
                if (!got_argument[i] && positional < arguments.length)
                {
                    static if (is(const(Variant) : typeof(parameters[i])))
                        parameters[i] = arguments[positional];
                    else
                    {
                        error = from_variant(arguments[positional], parameters[i]);
                        if (error)
                        {
                            error = tconcat("Argument '", Names[i],
                                            "' error: ", error);
                            goto done;
                        }
                    }
                    got_argument[i] = true;
                    ++positional;
                }
            }
        }
        if (positional != arguments.length && !has_arguments)
        {
            error = "Too many positional arguments";
            goto done;
        }
    }

    static foreach (i, Parameter; Parameters_)
    {{
        static if (Names[i] == "args")
        {
            static assert(is(const(Variant)[] : Parameter),
                          "`args` parameter must be of type const(Variant)[]");
            parameters[i] = arguments;
        }
        else static if (Names[i] == "named-args")
        {
            static assert(is(const(NamedArgument)[] : Parameter),
                          "`named_args` parameter must be of type const(NamedArgument)[]");
            parameters[i] = named_arguments;
        }
        else static if (!is(Parameter : Nullable!Value, Value))
        {
            if (!got_argument[i])
            {
                error = tconcat("Missing argument: ", Names[i]);
                goto done;
            }
        }
    }}

done:
    return parameters;
}


unittest
{
    static int hard_add(int a, int b)
    {
        return a + b;
    }

    static int contextual_add(Object, int a, int b)
    {
        return a + b;
    }

    static CallResult soft_add(void*, ref CallContext,
                               const Variant[] arguments,
                               const NamedArgument[])
    {
        CallResult result;
        result.value = Variant(arguments[0].asLong + arguments[1].asLong);
        result.has_value = true;
        return result;
    }

    struct NoSuggestions
    {
        template opCall(T)
        {
        }
    }

    CallContext context;

    Function hard = Function.create!(hard_add, typeof(null), NoSuggestions)(null);
    int hard_result;
    assert(hard.call(context, hard_result, 2, 3));
    assert(hard_result == 5);

    Variant[2] soft_arguments = [ Variant(7), Variant(4) ];
    CallResult soft_to_hard = hard.call(context, soft_arguments[]);
    assert(!soft_to_hard.error && soft_to_hard.value.asLong == 11);

    Function contextual = Function.create_contextual!(
        contextual_add, typeof(null), NoSuggestions)(null);
    NamedArgument[2] named_arguments = [
        NamedArgument("a", Variant(8)),
        NamedArgument("b", Variant(5)),
    ];
    CallResult contextual_result = contextual.call(context, null, named_arguments[]);
    assert(!contextual_result.error && contextual_result.value.asLong == 13);

    Function soft = Function.create_generic!(int, int, int)(null, &soft_add);
    int hard_to_soft;
    assert(soft.call(context, hard_to_soft, 6, 5));
    assert(hard_to_soft == 11);

    CallResult soft_to_soft = soft.call(context, soft_arguments[]);
    assert(!soft_to_soft.error && soft_to_soft.value.asLong == 11);
}
