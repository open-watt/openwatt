module manager.console.collection_commands;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.result;
import urt.string;
import urt.variant;

import manager.base;
import manager.collection;
import manager.console;
import manager.console.command;

nothrow @nogc:


void addCollectionCommands(Scope s, ref BaseCollection collection)
{
    if (collection.typeInfo)
    {
        s.addCommand(defaultAllocator.allocT!CollectionAddCommand(s.console, collection));
        s.addCommand(defaultAllocator.allocT!CollectionRemoveCommand(s.console, collection));
    }
    s.addCommand(defaultAllocator.allocT!CollectionGetCommand(s.console, collection));
    s.addCommand(defaultAllocator.allocT!CollectionSetCommand(s.console, collection));
    s.addCommand(defaultAllocator.allocT!CollectionResetCommand(s.console, collection));
    s.addCommand(defaultAllocator.allocT!CollectionPrintCommand(s.console, collection));
}


class CollectionAddCommand : Command
{
nothrow @nogc:

    this(ref Console console, ref BaseCollection collection)
    {
        super(console, StringLit!"add");
        this.collection = &collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs)
    {
        if (args.length != 0)
        {
            session.writeLine("Usage: add [<property=value> [...]]");
            return null;
        }

        // find the name if it was given
        const(char)[] name = null;
        foreach (ref arg; namedArgs)
        {
            if (arg.name == "name")
            {
                assert(arg.value.isString, "TODO: what if it's not a string?!");
                name = arg.value.asString();
                if (collection.exists(name))
                {
                    session.writeLine("Item with name '", name, "' already exists");
                    return null;
                }
                if (collection.typeInfo.validateName)
                {
                    if (const(char)[] error = collection.typeInfo.validateName(name))
                    {
                        session.writeLine(error);
                        return null;
                    }
                }
                break;
            }
        }

        // create an instance
        BaseObject item = collection.alloc(name);

        // set all the properties...
        foreach (ref arg; namedArgs)
        {
            if (arg.name[] == "name")
                continue;
            if (item.set(arg.name, arg.value))
            {
                session.writeLine("Invalid value for property '", arg.name, "': ", arg.value);
                defaultAllocator.freeT(item);
                return null;
            }
        }
        collection.add(item);

        // TODO: maybe something better? perhaps a virtual on the object which lets it supply a creation message?
        //       how do we know what properties are relevant for the create logs?
        writeInfo("Create ", item.type, ": '", item.name, "'");

        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, *collection, SuggestFlags.Add);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, *collection, SuggestFlags.Add);
    }

private:
    BaseCollection* collection;
}

class CollectionRemoveCommand : Command
{
nothrow @nogc:

    this(ref Console console, ref BaseCollection collection)
    {
        super(console, StringLit!"remove");
        this.collection = &collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs)
    {
        if (args.length != 1 || namedArgs.length != 0)
        {
            session.writeLine("Usage: remove <name>");
            return null;
        }

        // gotta destroy the item, clean it up from everywhere it's referenced...

        assert(false, "TODO: lots of work to delete things!");
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, *collection, SuggestFlags.Remove);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, *collection, SuggestFlags.Remove);
    }

private:
    BaseCollection* collection;
}

class CollectionGetCommand : Command
{
nothrow @nogc:

    this(ref Console console, ref BaseCollection collection)
    {
        super(console, StringLit!"get");
        this.collection = &collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs)
    {
        if (args.length != 2 || namedArgs.length != 0)
        {
            session.writeLine("Usage: get <name> <property>");
            return null;
        }
        if (!args[0].isString)
        {
            session.writeLine("'name' must be a string");
            return null;
        }
        if (!args[1].isString)
        {
            session.writeLine("'property' must be a string");
            return null;
        }

        BaseObject item = collection.get(args[0].asString());
        if (!item)
        {
            session.writeLine("No item '", args[0].asString(), '\'');
            return null;
        }

        Variant value = item.get(args[1].asString());

        char[1024] buffer = void;
        ptrdiff_t l = value.toString(buffer, null, null);
        assert(l >= 0, "TODO: fix stringify-failure, or print error...?");
        if (l > 0)
            session.writeLine(buffer[0..l]);
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, *collection, SuggestFlags.Get);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, *collection, SuggestFlags.Get);
    }

private:
    BaseCollection* collection;
}

class CollectionSetCommand : Command
{
nothrow @nogc:

    this(ref Console console, ref BaseCollection collection)
    {
        super(console, StringLit!"set");
        this.collection = &collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs)
    {
        if (args.length != 1 || namedArgs.length == 0)
        {
            session.writeLine("Usage: set <name> <property=value> [<property=value> [...]]");
            return null;
        }
        if (!args[0].isString)
        {
            session.writeLine("'name' must be a string");
            return null;
        }

        BaseObject item = collection.get(args[0].asString());
        if (!item)
        {
            session.writeLine("No item '", args[0].asString(), '\'');
            return null;
        }

        foreach (ref arg; namedArgs)
        {
            StringResult result = item.set(arg.name, arg.value);
            if (!result)
            {
                session.writeLine("Set '", arg.name, "\' failed: ", result.message);
                // TODO: should we bail out at first error, or try and set the rest?
//                return null;
            }
        }
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, *collection, SuggestFlags.Set);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, *collection, SuggestFlags.Set);
    }

private:
    BaseCollection* collection;
}

class CollectionResetCommand : Command
{
nothrow @nogc:

    this(ref Console console, ref BaseCollection collection)
    {
        super(console, StringLit!"reset");
        this.collection = &collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs)
    {
        if (namedArgs.length != 0)
        {
            session.writeLine("Usage: reset [<name>] [<property> [...]]");
            return null;
        }
        foreach (i, ref a; args)
        {
            if (!a.isString)
            {
                session.writeLine("arguments must be strings");
                return null;
            }
        }

        static void resetItem(BaseObject item, const Variant[] args)
        {
            if (args.length == 0)
            {
                foreach (ref prop; item.properties)
                    item.reset(prop.name);
            }
            else
            {
                foreach (ref arg; args)
                    item.reset(arg.asString());
            }
        }

        // TODO: first arg may not be an item name; it may be a property name applied to all items...
        BaseObject item = args.length > 0 ? collection.get(args[0].asString()) : null;
        if (item)
            resetItem(item, args[1 .. $]);
        else
        {
            foreach (i; collection.values)
                resetItem(i, args[0 .. $]);
        }
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, *collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, *collection, SuggestFlags.Reset);
    }

private:
    BaseCollection* collection;
}

// TODO: enable/disbale commands, which act on multiple items...

// TODO: export command which calls and returns item.exportConfig(), but also works on full collections...

class CollectionPrintCommand : Command
{
nothrow @nogc:

    this(ref Console console, ref BaseCollection collection)
    {
        super(console, StringLit!"print");
        this.collection = &collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs)
    {
        assert(false, "TODO!");
//        BaseObject item = args.length > 0 ? collection.get(args[0].asString()) : null;
//        if (!item)
//        {
//            session.writeLine("No item '", args[0].asString(), '\'');
//            return null;
//        }
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, *collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, *collection, SuggestFlags.Reset);
    }

private:
    BaseCollection* collection;
}

private:

enum SuggestFlags : uint
{
    None        = 0,
    NoItem      = 1 << 0,
    OptItem     = 1 << 1,
    MultiItem   = 1 << 2,
    NoProps     = 1 << 3,
    NoValues    = 1 << 4,
    OnlyGet     = 1 << 5,
    OnlySet     = 1 << 6,

    Add = NoItem | OnlySet,
    Remove = NoProps,
    Get = OnlyGet | NoValues,
    Set = OnlySet,
    Reset = OptItem | OnlySet | NoValues,
    Enable = OptItem | MultiItem | NoProps,
    Disable = OptItem | MultiItem | NoProps,
    Export = OptItem | MultiItem | NoProps,
}

MutableString!0 complete(const(char)[] cmdLine, ref BaseCollection collection, SuggestFlags flags)
{
    MutableString!0 result = cmdLine;
    Array!String tokens;

    size_t firstToken = 0, lastToken = cmdLine.length;
    while (firstToken < cmdLine.length && isSeparator(cmdLine[firstToken]))
        ++firstToken;
    while (lastToken > firstToken && !isSeparator(cmdLine[lastToken - 1]))
        --lastToken;
    const(char)[] lastTok = cmdLine[lastToken .. $];

    BaseObject item;
    if (!(flags & SuggestFlags.NoItem))
    {
        if (lastToken == firstToken)
        {
            // complete item name
            foreach (ref k; collection.keys)
            {
                if (k[].startsWith(lastTok))
                    tokens ~= k;
            }
            result ~= getCompletionSuffix(lastTok, tokens);
            if (result[$-1] != ' ')
                return result;

            tokens.clear();
            lastToken = result.length;
            lastTok = null;
        }

        if (flags & SuggestFlags.NoProps)
            return result;

        // get the object in question...
        const(char)[] name;
        for (size_t i = firstToken; i < result.length; ++i)
        {
            if (isSeparator(result[i]))
            {
                name = result[firstToken .. i];
                break;
            }
        }

        item = collection.get(name);
        if (!item)
            return result;
    }

    // complete properties
    Array!(const(Property)*) itemProps;
    if (item)
        itemProps = item.properties();
    const(Property*)[] props = item ? itemProps[] : collection.typeInfo.properties;

    size_t equals = lastTok.findFirst('=');
    if (equals == lastTok.length)
    {
        foreach (ref p; props)
        {
            if (((flags & SuggestFlags.OnlyGet) && !p.get) ||
                ((flags & SuggestFlags.OnlySet) && !p.set))
                continue;
            if (p.name[].startsWith(lastTok))
                tokens ~= p.name;
        }
        result ~= getCompletionSuffix(lastTok, tokens);
        lastTok = result[lastToken .. $];
        if (lastTok.length > 0)
        {
            if (lastTok[$-1] == ' ')
            {
                if (flags & SuggestFlags.NoValues)
                    return result;

                result[$-1] = '=';
                foreach (ref p; props)
                {
                    if (p.name[] != lastTok[0 .. $-1])
                        continue;

                    if (p.suggest)
                    {
                        tokens = p.suggest(null);
                        result ~= getCompletionSuffix(null, tokens);
                    }
                    break;
                }
            }
        }
    }
    else if (!(flags & SuggestFlags.NoValues))
    {
        foreach (ref p; props)
        {
            if (p.name[] != lastTok[0 .. equals])
                continue;

            if (p.suggest)
            {
                tokens = p.suggest(lastTok[equals + 1 .. $]);
                result ~= getCompletionSuffix(lastTok[equals + 1 .. $], tokens);
            }
            break;
        }
    }
    return result;
}

Array!String suggest(const(char)[] cmdLine, ref BaseCollection collection, SuggestFlags flags)
{
    cmdLine.trimFront();

    // get incomplete argument
    ptrdiff_t lastToken = cmdLine.length;
    while (lastToken > 0)
    {
        if (cmdLine[lastToken - 1].is_whitespace)
            break;
        --lastToken;
    }
    const(char)[] lastTok = cmdLine[lastToken .. $];

    Array!String results;

    BaseObject item;
    if (!(flags & SuggestFlags.NoItem))
    {
        if (lastToken == 0)
        {
            // complete item name
            foreach (ref k; collection.keys)
                if (k[].startsWith(lastTok))
                    results ~= k;
            return results;
        }

        if (flags & SuggestFlags.NoProps)
            return results;

        // get the object in question...
        const(char)[] name;
        for (size_t i = 1; ; ++i)
        {
            if (cmdLine[i].is_whitespace)
            {
                name = cmdLine[0 .. i];
                break;
            }
        }
        item = collection.get(name);
        if (!item)
            return results;
    }

    // get the property list
    Array!(const(Property)*) itemProps;
    if (item)
        itemProps = item.properties();
    const(Property*)[] props = item ? itemProps[] : collection.typeInfo.properties;

    // if the partial argument alrady contains an '='
    size_t equals = lastTok.findFirst('=');
    if (equals == lastTok.length)
    {
        foreach (ref p; props)
        {
            if (((flags & SuggestFlags.OnlyGet) && !p.get) ||
                ((flags & SuggestFlags.OnlySet) && !p.set))
                continue;
            if (p.name[].startsWith(lastTok))
                results ~= p.name;
        }
    }
    else if (!(flags & SuggestFlags.NoValues))
    {
        foreach (ref p; props)
        {
            if (p.name[] == lastTok[0 .. equals])
            {
                if (p.suggest)
                    return p.suggest(lastTok[equals + 1 .. $]);
            }
        }
    }
    return results;
}
