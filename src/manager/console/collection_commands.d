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


void add_collection_commands(ref Console console, Scope* n, BaseCollection collection)
{
    assert(n._cmd_len == 0, "scope already has commands");

    n.collection_type = collection.type_info;

    Command[12]* shared_ = shared_commands(console);

    // Point at the appropriate shared strip in the side-array. Layouts:
    //   [0..7)   full: add, get, list, print, remove, reset, set
    //   [1..7)   no add: get, list, print, remove, reset, set
    //   [7..12)  no add, no remove: get, list, print, reset, set
    // If the scope later gets an extension command via register_command,
    // Console.add_command will promote it into _commands.
    if (collection.type_info && collection.type_info.create)
    {
        n._cmd_ptr = shared_.ptr;
        n._cmd_len = 7;
    }
    else if (collection.type_info)
    {
        n._cmd_ptr = shared_.ptr + 1;
        n._cmd_len = 6;
    }
    else
    {
        n._cmd_ptr = shared_.ptr + 7;
        n._cmd_len = 5;
    }
}


class CollectionAddCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"add");
    }

    override CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        BaseCollection collection = _scope.collection;

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
                if (collection.get(name))
                {
                    session.write_line("Item with name '", name, "' already exists");
                    return null;
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
            StringResult r = item.set(arg.name, arg.value);
            if (!r)
            {
                session.write_line("Invalid value for property: ", arg.name, "=", arg.value, " - ", r.message);
                defaultAllocator.freeT(item);
                return null;
            }
        }
        collection.add(item);

        // TODO: maybe something better? perhaps a virtual on the object which lets it supply a creation message?
        //       how do we know what properties are relevant for the create logs?
        item.log.info("created");

        // HACK: advance the state machine synchronously so subsequent script lines
        // have a chance to work when the early startup creates things.
        // this should be removed, and replaced by a more comprehensive latent startup tolerance.
        if (auto active = cast(ActiveObject)item)
            active.do_update();

        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _scope.collection, SuggestFlags.Add);
    }

    final override Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        return .suggest(cmdLine, _scope.collection, SuggestFlags.Add);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Create a new item in this collection, setting any given\n"
         ~ "properties on it.\n"
         ~ "Usage: add [name=<value>] [<property>=<value> ...]";
}

class CollectionRemoveCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"remove");
    }

    override CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        if (args.length != 1 || namedArgs.length != 0)
        {
            session.write_line("Usage: remove <name>");
            return null;
        }

        BaseObject item = _scope.collection.get(args[0].asString());
        if (!item)
        {
            session.write_line("No such item: ", args[0].asString());
            return null;
        }

        item.destroy();
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _scope.collection, SuggestFlags.Remove);
    }

    final override Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        return .suggest(cmdLine, _scope.collection, SuggestFlags.Remove);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Remove the named item from this collection.\nUsage: remove <name>";
}

class CollectionGetCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"get");
    }

    override CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        BaseCollection collection = _scope.collection;

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

        BaseObject item = collection.get(args[0].asString());
        if (!item)
        {
            session.write_line("No item '", args[0].asString(), '\'');
            return null;
        }

        result = item.get(args[1].asString());

        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _scope.collection, SuggestFlags.Get);
    }

    final override Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        return .suggest(cmdLine, _scope.collection, SuggestFlags.Get);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Read the value of a property on a named item.\nUsage: get <name> <property>";
}

class CollectionSetCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"set");
    }

    override CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        BaseCollection collection = _scope.collection;

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

        BaseObject item = collection.get(args[0].asString());
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

    final override MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _scope.collection, SuggestFlags.Set);
    }

    final override Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        return .suggest(cmdLine, _scope.collection, SuggestFlags.Set);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Change one or more properties on an existing item.\nUsage: set <name> <property>=<value> [<property>=<value> ...]";
}

class CollectionResetCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"reset");
    }

    override CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        BaseCollection collection = _scope.collection;

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
        BaseObject item = args.length > 0 ? collection.get(args[0].asString()) : null;
        if (item)
            reset_item(item, args[1 .. $]);
        else
        {
            foreach (i; collection.values)
                reset_item(i, args[0 .. $]);
        }
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _scope.collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        return .suggest(cmdLine, _scope.collection, SuggestFlags.Reset);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Reset properties to their defaults. With no arguments, resets\n"
         ~ "every property on every item. With a name, scopes to one item;\n"
         ~ "with property names, scopes to those properties.\n"
         ~ "Usage: reset [<name>] [<property> ...]";
}

// TODO: enable/disable commands, which act on multiple items...

// TODO: export command which calls and returns item.export_config(), but also works on full collections...

class CollectionListCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"list");
    }

    override CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        BaseCollection collection = _scope.collection;

        bool json_output;
        foreach (ref a; args)
        {
            if (a == "--json")
                json_output = true;
        }

        foreach (object; collection.values)
            result.asArray ~= Variant(object.name[]);

        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _scope.collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        return .suggest(cmdLine, _scope.collection, SuggestFlags.Reset);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "List the names of all items in this collection.\nUsage: list";
}

class CollectionPrintCommand : Command
{
nothrow @nogc:

    this(ref Console console)
    {
        super(console, StringLit!"print");
    }

    override CommandState execute(Session session, Scope* _scope, const Variant[] args, const NamedArgument[] namedArgs, out Variant result)
    {
        BaseCollection collection = _scope.collection;

        bool watch_mode = false;

        foreach (ref arg; args)
        {
            if (arg == "--json")
            {
                auto items = Array!Variant(Reserve, collection.item_count);
                foreach (item; collection.values)
                    items ~= item.gather();
                result = Variant(items.move);
                return null;
            }
            if (arg == "--watch" || arg == "-w")
                watch_mode = true;
        }

        if (watch_mode)
            return allocator.allocT!CollectionWatchState(session, this, collection);

        Table table;
        populate_collection_table(table, collection);
        table.render(session);
        return null;
    }

    final override MutableString!0 complete(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        version (ExcludeAutocomplete)
            return null;
        else
            return .complete(cmdLine, _scope.collection, SuggestFlags.Reset);
    }

    final override Array!String suggest(const(char)[] cmdLine, Scope* _scope, Scope* user_scope = null)
    {
        return .suggest(cmdLine, _scope.collection, SuggestFlags.Reset);
    }

    version (ExcludeHelpText) {} else
    override const(char)[] help(const(char)[] args) const
        => "Show a table of all items in this collection and their\n"
         ~ "properties. Use --watch for a live view; --json for machine\n"
         ~ "output.\n"
         ~ "Usage: print [--watch|-w] [--json]";
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

    override uint header_rows()
        => 1;

    override void render_content(uint offset, uint count, uint width)
    {
        if (width != _prev_width)
        {
            _sticky_widths[] = 0;
            _prev_width = width;
        }

        Table table;
        populate_collection_table(table, _collection);
        table.render_viewport(session, offset, count, _sticky_widths[]);
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

void populate_collection_table(ref Table table, BaseCollection collection)
{
    const(char)[][16] proplist;
    auto properties = collection.type_info.properties;

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
    foreach (item; collection.values)
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
}

Command[12]* shared_commands(ref Console console)
{
    if (console._coll_cmds[0] is null)
    {
        Command add    = defaultAllocator.allocT!CollectionAddCommand(console);
        Command remove = defaultAllocator.allocT!CollectionRemoveCommand(console);
        Command get    = defaultAllocator.allocT!CollectionGetCommand(console);
        Command set_   = defaultAllocator.allocT!CollectionSetCommand(console);
        Command reset  = defaultAllocator.allocT!CollectionResetCommand(console);
        Command list   = defaultAllocator.allocT!CollectionListCommand(console);
        Command print  = defaultAllocator.allocT!CollectionPrintCommand(console);

        // [0..7) alphabetical
        console._coll_cmds[0] = add;
        console._coll_cmds[1] = get;
        console._coll_cmds[2] = list;
        console._coll_cmds[3] = print;
        console._coll_cmds[4] = remove;
        console._coll_cmds[5] = reset;
        console._coll_cmds[6] = set_;
        // [7..12) alphabetical, no add/remove
        console._coll_cmds[7]  = get;
        console._coll_cmds[8]  = list;
        console._coll_cmds[9]  = print;
        console._coll_cmds[10] = reset;
        console._coll_cmds[11] = set_;
    }
    return &console._coll_cmds;
}

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
