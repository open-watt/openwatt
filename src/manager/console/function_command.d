module manager.console.function_command;

import urt.mem;
import urt.meta;
import urt.meta.nullable;
import urt.meta.tuple;
import urt.traits;
import urt.string;
import urt.string.format;

public import manager.console; 
public import manager.console.command; 
public import manager.console.expression; 
public import manager.console.session; 


class FunctionCommand : Command
{
nothrow @nogc:

	alias GenericCall = const(char)[] function(Session, KVP[], void*) nothrow @nogc;

	static FunctionCommand create(alias fun, Instance)(ref Console console, Instance i, const(char)[] commandName = null)
	{
		static assert(is(Parameters!fun[0] == Session), "First parameter must be manager.console.session.Session for command hander function");

		enum FunctionName = transformCommandName(__traits(identifier, fun));

		static const(char)[] functionAdapter(Session session, KVP[] parameters, void* instance)
		{
			bool success = false;
			auto args = makeArgTuple!fun(parameters, success);
			if (!success)
			{
				// we should report some sort of error...
				// but we'll need to improve the API to report error status
				return null;
			}
			static if (is(__traits(parent, fun)))
			{
				static if (is(ReturnType!fun == void))
				{
					__traits(getMember, cast(__traits(parent, fun))instance, __traits(identifier, fun))(session, args.expand);
					return null;
				}
				else
				{
					auto r = __traits(getMember, cast(__traits(parent, fun))instance, __traits(identifier, fun))(session, args.expand);
					return tconcat(r);
				}
			}
			else
			{
				static if (is(ReturnType!fun == void))
				{
					fun(session, args.expand);
					return null;
				}
				else
				{
					auto r = fun(session, args.expand);
					return tconcat(r);
				}
			}
		}

		return console.m_allocator.allocT!FunctionCommand(console, commandName ? commandName.makeString(defaultAllocator) : StringLit!FunctionName, cast(void*)i, &functionAdapter);
	}


	this(ref Console console, String scopeName, void* instance, GenericCall fn)
	{
		super(console, scopeName);
		this.instance = instance;
		this.fn = fn;
	}

	override CommandState execute(Session session, const(char)[] cmdLine)
	{
		import urt.mem.scratchpad;
		import urt.mem.region;

		void[] scratch = allocScratchpad();
		scope(exit) freeScratchpad(scratch);

		// TODO: move this to its own function...
		Region* region = scratch.makeRegion;
		KVP[] params = region.allocArray!KVP(40);
		assert(params !is null);
		size_t numParams = 0;

		while (!cmdLine.empty)
		{
			KVP kvp = cmdLine.takeKVP;
			if (kvp.k.type == Token.Type.Error)
			{
				session.writeLine("Error: ", kvp.k.token);
				return null;
			}
			if (!kvp.k.type == Token.Type.None)
				params[numParams++] = kvp;
		}

		const(char)[] result = fn(session, params[0 .. numParams], instance);

		// TODO: when a function returns a token, it might be fed into the calling context?

		return null;
	}

private:
	void* instance;
	GenericCall fn;
}


private:


char[] transformCommandName(const(char)[] name)
{
	name = name.length > 0 && name[0] == '_' ? name[1 .. $] : name;
	char[] result = name.dup;
	foreach (i, c; result)
	{
		if (c == '_')
			result[i] = '-';
	}
	return result;
}

auto makeArgTuple(alias F)(KVP[] args, out bool success)
	if (isSomeFunction!F)
{
	import urt.meta;

	alias Params = staticMap!(Unqual, Parameters!F[1 .. $]);
	alias ParamNames = ParameterIdentifierTuple!F[1 .. $];

	Tuple!Params params;
	success = true;

	outer: foreach (ref kvp; args)
	{
		// validate argument name...
		if (kvp.k.type != Token.Type.Identifier)
		{
			success = false;
			break;
		}

		const(char)[] key = kvp.k.token[];
		arg: switch (key)
		{
			static foreach (i, P; Params)
			{
				case Alias!(transformCommandName(ParamNames[i])):
					if (!kvp.v.tokenToValue(params[i]))
					{
						success = false;
						break outer;
					}
					break arg;
			}
			default:
				assert(false, tconcat("Unknown parameter '", key, "'"));
				break;
		}
	}
	return params;
}

const(char)[] tokenValue(ref const Token t, bool acceptString) nothrow @nogc
{
	if (t.type == Token.Type.Command)
	{
		assert(false, "TODO: [command] expressions need to be evaluated... but what if the user calls a command with latency?");
	}
	else if (t.type == Token.Type.String)
	{
		if (acceptString)
			return t.token[].unQuote;
		else
			return null;
	}
	return t.token[];
}

bool tokenToValue(ref const Token t, out bool r) nothrow @nogc
{
	const(char)[] v = tokenValue(t, false);
	if (!v)
		return false;
	if (v[] == "true" || v[] == "yes")
	{
		r = true;
		return true;
	}
	else if (v[] == "false" || v[] == "no")
	{
		r = false;
		return true;
	}
	return false;
}

bool tokenToValue(I)(ref const Token t, out I r) nothrow @nogc if (isSomeInt!I)
{
	import urt.conv : parseInt;
	const(char)[] v = tokenValue(t, false);
	if (!v)
		return false;
	size_t taken;
	r = cast(I)v.parseInt(&taken);
	return taken > 0;
}

bool tokenToValue(F)(ref const Token t, out F r) nothrow @nogc if (isSomeFloat!F)
{
	import urt.conv : parseFloat;
	const(char)[] v = tokenValue(t, false);
	if (!v)
		return false;
	size_t taken;
	r = cast(F)v.parseFloat(&taken);
	return taken > 0;
}

bool tokenToValue(S : const(char)[])(ref const Token t, out S r) nothrow @nogc
{
	const(char)[] v = tokenValue(t, true);
	r = v;
	return true;
}

bool tokenToValue(T)(ref const Token t, out T r) nothrow @nogc if (is(T U == enum))
{
	// try and parse a key from the string...
	const(char)[] v = tokenValue(t, false);
	if (!v)
		return false;
	switch (v)
	{
		static foreach(E; __traits(allMembers, T))
		{
			case Alias!(toLower(E)):
				r = __traits(getMember, T, E);
				return true;
		}
		default:
			break;
	}

	// else parse the base type?
//	const(char)[] v = tokenValue(t, false);

	return false;
}

bool tokenToValue(T : U[], U)(ref const Token t, out T r) nothrow @nogc if (!is(U : char))
{
	const(char)[] v = tokenValue(t, false);

	// TODO: this is tricky, because we need to split on ',' but also need to re-tokenise all the elements...
	//       trouble is; what if the whole token is a string? did it even detect the token type correctly in the first place?

	const(char)[] tmp = v;
	int numArgs = 0;
	while (tmp.split(','))
		++numArgs;

	r = tempAllocator().allocArray!U(numArgs);
	int i = 0;
	while (!v.empty)
	{
		if (!tokenToValue!U(Token(v.split(',')), r[i++]))
			return false;
	}
	return true;
}



bool tokenToValue(T : Nullable!U, U)(ref const Token t, out T r) nothrow @nogc
{
	U tmp;
	bool success = tokenToValue(t, tmp);
	if (success)
		r = tmp;
	return success;
}
