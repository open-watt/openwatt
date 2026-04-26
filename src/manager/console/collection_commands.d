module manager.console.collection_commands;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.result;
import urt.string;
import urt.string.ansi;
import urt.time;
import urt.variant;

import manager.base;
import manager.collection;
import manager.console;
import manager.console.command;
import manager.console.live_view;
import manager.console.session : ClientFeatures;
import manager.console.table;

nothrow @nogc:


void add_collection_commands(Scope s, BaseCollection collection)
{
    if (collection.type_info)
    {
        if (collection.type_info.create)
            s.add_command(defaultAllocator.allocT!CollectionAddCommand(s.console, collection));
        s.add_command(defaultAllocator.allocT!CollectionRemoveCommand(s.console, collection));
    }
    s.add_command(defaultAllocator.allocT!CollectionGetCommand(s.console, collection));
    s.add_command(defaultAllocator.allocT!CollectionSetCommand(s.console, collection));
    s.add_command(defaultAllocator.allocT!CollectionResetCommand(s.console, collection));
    s.add_command(defaultAllocator.allocT!CollectionListCommand(s.console, collection));
    s.add_command(defaultAllocator.allocT!CollectionPrintCommand(s.console, collection));
}


class CollectionAddCommand : Command
{
nothrow @nogc:

    this(ref Console console, BaseCollection collection)
    {
        super(console, StringLit!"add");
        _collection = collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length != 0)
        {
            session.write_line("Usage: add [<property=value> [...]]");
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
                if (_collection.get(name))
                {
                    session.write_line("Item with name '", name, "' already exists");
                    return null;
                }
                break;
            }
        }

        // create an instance
        BaseObject item = _collection.alloc(name);

        // set all the properties...
        foreach (ref arg; namedArgs)
        {
            if (arg.name[] == "name")
                continue;
            StringResult r = item.set(arg.name, arg.value);
            if (!r)
            {
                session.write_line("Invalid value for property: ", arg.name, "=", arg.value, " - ", r.message);
                defaultAllocator.freeT(item);
                return null;
            }
        }
        _collection.add(item);

        // TODO: maybe something better? perhaps a virtual on the object which lets it supply a creation message?
        //       how do we know what properties are relevant for the create logs?
        item.log.info("created");

        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _collection, SuggestFlags.Add);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, _collection, SuggestFlags.Add);
    }

private:
    BaseCollection _collection;
}

class CollectionRemoveCommand : Command
{
nothrow @nogc:

    this(ref Console console, BaseCollection collection)
    {
        super(console, StringLit!"remove");
        _collection = collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length != 1 || namedArgs.length != 0)
        {
            session.write_line("Usage: remove <name>");
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
            return .complete(cmdLine, _collection, SuggestFlags.Remove);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, _collection, SuggestFlags.Remove);
    }

private:
    BaseCollection _collection;
}

class CollectionGetCommand : Command
{
nothrow @nogc:

    this(ref Console console, BaseCollection collection)
    {
        super(console, StringLit!"get");
        _collection = collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length != 2 || namedArgs.length != 0)
        {
            session.write_line("Usage: get <name> <property>");
            return null;
        }
        if (!args[0].isString)
        {
            session.write_line("'name' must be a string");
            return null;
        }
        if (!args[1].isString)
        {
            session.write_line("'property' must be a string");
            return null;
        }

        BaseObject item = _collection.get(args[0].asString());
        if (!item)
        {
            session.write_line("No item '", args[0].asString(), '\'');
            return null;
        }

        result = item.get(args[1].asString());

        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _collection, SuggestFlags.Get);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, _collection, SuggestFlags.Get);
    }

private:
    BaseCollection _collection;
}

class CollectionSetCommand : Command
{
nothrow @nogc:

    this(ref Console console, BaseCollection collection)
    {
        super(console, StringLit!"set");
        _collection = collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length != 1 || namedArgs.length == 0)
        {
            session.write_line("Usage: set <name> <property=value> [<property=value> [...]]");
            return null;
        }
        if (!args[0].isString)
        {
            session.write_line("'name' must be a string");
            return null;
        }

        BaseObject item = _collection.get(args[0].asString());
        if (!item)
        {
            session.write_line("No item '", args[0].asString(), '\'');
            return null;
        }

        foreach (ref arg; namedArgs)
        {
            StringResult r = item.set(arg.name, arg.value);
            if (!r)
            {
                session.write_line("Set '", arg.name, "\' failed: ", r.message);
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
            return .complete(cmdLine, _collection, SuggestFlags.Set);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, _collection, SuggestFlags.Set);
    }

private:
    BaseCollection _collection;
}

class CollectionResetCommand : Command
{
nothrow @nogc:

    this(ref Console console, BaseCollection collection)
    {
        super(console, StringLit!"reset");
        _collection = collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (namedArgs.length != 0)
        {
            session.write_line("Usage: reset [<name>] [<property> [...]]");
            return null;
        }
        foreach (i, ref a; args)
        {
            if (!a.isString)
            {
                session.write_line("arguments must be strings");
                return null;
            }
        }

        static void reset_item(BaseObject item, const Variant[] args)
        {
            if (args.length == 0)
            {
                foreach (ref prop; item.properties)
                    item.reset(prop.name[]);
            }
            else
            {
                foreach (ref arg; args)
                    item.reset(arg.asString());
            }
        }

        // TODO: first arg may not be an item name; it may be a property name applied to all items...
        BaseObject item = args.length > 0 ? _collection.get(args[0].asString()) : null;
        if (item)
            reset_item(item, args[1 .. $]);
        else
        {
            foreach (i; _collection.values)
                reset_item(i, args[0 .. $]);
        }
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, _collection, SuggestFlags.Reset);
    }

private:
    BaseCollection _collection;
}

// TODO: enable/disable commands, which act on multiple items...

// TODO: export command which calls and returns item.export_config(), but also works on full collections...

class CollectionListCommand : Command
{
nothrow @nogc:

    this(ref Console console, BaseCollection collection)
    {
        super(console, StringLit!"list");
        _collection = collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        bool json_output;
        foreach (ref a; args)
        {
            if (a == "--json")
                json_output = true;
        }

        foreach (object; _collection.values)
            result.asArray ~= Variant(object.name[]);

        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, _collection, SuggestFlags.Reset);
    }

private:
    BaseCollection _collection;
}

class CollectionPrintCommand : Command
{
nothrow @nogc:

    this(ref Console console, BaseCollection collection)
    {
        super(console, StringLit!"print");
        _collection = collection;
    }

    override CommandState execute(Session session, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        const(Property*)[] properties = _collection.type_info.properties;

        bool watch_mode = false;

        foreach (ref arg; args)
        {
            if (arg == "--json")
            {
                auto items = Array!Variant(Reserve, _collection.item_count);
                foreach (item; _collection.values)
                    items ~= item.gather();
                result = Variant(items.move);
                return null;
            }
            if (arg == "--watch" || arg == "-w")
                watch_mode = true;
        }

        if (watch_mode)
            return allocator.allocT!CollectionWatchState(session, this, _collection);

        print_table(session, properties);
        return null;
    }

    final void print_table(Session session, const(Property*)[] properties)
    {
        const(char)[][16] proplist;

        Table table;
        table.add_column("");

        foreach (p; properties)
        {
            if (!p.get || p.name[] == "flags")
                continue;
            if (!prop_visible(p.flags, proplist, p.name[]))
                continue;
            auto alignment = is_numeric_prop(p.type[0][]) ? Table.TextAlign.right : Table.TextAlign.left;
            table.add_column(p.name[], alignment);
        }
        foreach (item; _collection.values)
        {
            table.add_row();
            table.cell(format_flags(item.flags));

            foreach (p; properties)
            {
                if (!p.get || p.name[] == "flags")
                    continue;
                if (!prop_visible(p.flags, proplist, p.name[]))
                    continue;
                table.cell(p.get(item));
            }
        }

        table.render(session);
    }

    final override MutableString!0 complete(const(char)[] cmdLine)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine)
    {
        return .suggest(cmdLine, _collection, SuggestFlags.Reset);
    }

package:
    BaseCollection _collection;
}

class CollectionWatchState : LiveViewState
{
nothrow @nogc:

    this(Session session, CollectionPrintCommand command, BaseCollection collection)
    {
        super(session, command);
        _collection = collection;
    }

    override uint content_height()
        => cast(uint)_collection.item_count;

    override void render_content(uint offset, uint count, uint width)
    {
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }
        const(char)[][16] proplist;
        auto properties = _collection.type_info.properties;

        Table table;
        table.add_column("");
        foreach (p; properties)
        {
            if (!p.get || p.name[] == "flags")
                continue;
            if (!prop_visible(p.flags, proplist, p.name[]))
                continue;
            auto alignment = is_numeric_prop(p.type[0][]) ? Table.TextAlign.right : Table.TextAlign.left;
            table.add_column(p.name[], alignment);
        }

        foreach (item; _collection.values)
        {
            table.add_row();
            table.cell(format_flags(item.flags));
            foreach (p; properties)
            {
                if (!p.get || p.name[] == "flags")
                    continue;
                if (!prop_visible(p.flags, proplist, p.name[]))
                    continue;
                table.cell(p.get(item));
            }
        }

        auto avail = count > 0 ? count - 1 : 0;  // reserve 1 row for table header
        table.render_viewport(session, offset, avail, _sticky_widths[]);
    }

    override const(char)[] status_text()
    {
        import urt.string.format : tformat;
        return tformat("{0} items", _collection.item_count);
    }

private:
    BaseCollection _collection;
    size_t[Table.max_cols] _sticky_widths;
    uint _prev_width;
}

private:

const(char)[] format_flags(ObjectFlags f)
{
    static char[8] buf; // a static buffer!! ewoo!
    size_t n = 0;
    foreach (i; 0 .. 8)
        if (f & (1 << i))
            buf[n++] = "DTXIRSLH"[i];
    return buf[0 .. n];
}

bool prop_visible(ubyte flags, const(char)[][] proplist, const(char)[] name)
{
    if (flags & 4)
        return false;
    if ((flags & (1 | 2)) != 0)
        return true;
    foreach (prop; proplist)
        if (name[] == prop[])
            return true;
    return false;
}

bool is_numeric_prop(const(char)[] type)
{
    if (type.length == 0)
        return false;
    if (type == "int" || type == "uint" || type == "byte" || type == "num")
        return true;
    if (type.length > 2 && type[0..2] == "q_")
        return true;
    return false;
}

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

MutableString!0 complete(const(char)[] cmdLine, BaseCollection collection, SuggestFlags flags)
{
    MutableString!0 result = cmdLine;
    Array!String tokens;

    size_t firstToken = 0, lastToken = cmdLine.length;
    while (firstToken < cmdLine.length && is_separator(cmdLine[firstToken]))
        ++firstToken;
    while (lastToken > firstToken && !is_separator(cmdLine[lastToken - 1]))
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
            result ~= get_completion_suffix(lastTok, tokens);
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
            if (is_separator(result[i]))
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
    const(Property*)[] props = item ? itemProps[] : collection.type_info.properties;

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
        result ~= get_completion_suffix(lastTok, tokens);
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
                        result ~= get_completion_suffix(null, tokens);
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
                result ~= get_completion_suffix(lastTok[equals + 1 .. $], tokens);
            }
            break;
        }
    }
    return result;
}

Array!String suggest(const(char)[] cmdLine, BaseCollection collection, SuggestFlags flags)
{
    cmdLine = cmdLine.trimFront();

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
    const(Property*)[] props = item ? itemProps[] : collection.type_info.properties;

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
