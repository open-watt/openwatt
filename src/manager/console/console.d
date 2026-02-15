module manager.console.console;

import urt.array;
import urt.map;
import urt.mem;
import urt.string;
import urt.string.format;
import urt.util;

import manager : g_app;
import manager.collection;
import manager.console.builtin_commands;
import manager.console.command;
import manager.console.function_command;
import manager.console.session;
import manager.expression;

nothrow @nogc:


/// Find a console instance by name.
/// \param identifier
///  Name of the console instance to find.
/// \returns Pointer to the console instance, or `nullptr` if no console with that name exists.
Console* findConsole(const(char)[] identifier) nothrow @nogc
{
    Console* instance = g_console_instances;
    while (instance && instance._identifier != identifier[])
        instance = instance._next_console_instance;
    return instance;
}


struct Console
{
nothrow @nogc:

    Application appInstance;

    Scope root;
//    Command[] commands;

    this() @disable;
    this(this) @disable;

    this(Application appInstance, String identifier, NoGCAllocator allocator, NoGCAllocator tempAllocator = null)
    {
        this.appInstance = appInstance;
        _allocator = allocator;
        _tempAllocator = tempAllocator ? tempAllocator : allocator;
        _identifier = identifier;

        // add the console instance to the registry
        // TODO: this is not threadsafe! creating/destroying console instances should be threadsafe!
        assert(findConsole(identifier) is null, tconcat("Console '", identifier[], "' already exists!"));
        _next_console_instance = g_console_instances;
        g_console_instances = &this;

        root = _allocator.allocT!Scope(this, String(null));
        RegisterBuiltinCommands(this);
    }

    ~this()
    {
        assert(false);
//        for (dcConsoleSession* session : _sessions)
//            _allocator.Delete(session);
//
//        for (auto&& pair : _commands)
//            _allocator.Delete(pair.val);
//
//        dcDebugConsole* list = g_console_instances;
//        if (list == this)
//            g_console_instances = _next_console_instance;
//        else
//        {
//            while (list->_next_console_instance && list->_next_console_instance != this)
//                list = list->_next_console_instance;
//            BC_ASSERT(list != nullptr, "Console instance was not in the registry somehow?");
//            // _next_console_instance is 'this'; remove it from the list
//            list->_next_console_instance = list->_next_console_instance->_next_console_instance;
//        }
    }

    inout(Scope) get_root() inout nothrow @nogc
    {
        return root;
    }

    /// Update the console instance. This will update all attached sessions.
    void update()
    {
        foreach (session; _sessions)
        {
            if (session.is_attached)
                session.update();
//            if (!session.IsAttached)
//                _sessions.Erase(*it);
        }
    }

    /// Get the console's identifier
    const(char)[] identifier() { return _identifier[]; }

    /// Get the console's prompt string
    const(char)[] get_prompt() nothrow @nogc { return _prompt[]; }

    /// Set the prompt that text-based sessions will show when accepting commands.
    String set_prompt(String prompt)
    {
        return _prompt.swap(prompt);
    }

    /// Create a new session instance of the type `SessionType` (derived from Session) bound to this console instance.
    /// \param args
    ///  Constructor args forwarded to `SessionType`'s constructor.
    /// \returns A pointer to the new session instance.
    SessionType createSession(SessionType, Args...)(auto ref Args args)
        if (is(SessionType : Session))
        {
            SessionType session = _allocator.allocT!SessionType(this, forward!args);
            session.set_prompt(_prompt);
            _sessions ~= session;
            return session;
        }

    void destroy_session(Session session)
    {
        assert(session._console is &this, "Session does not belong to this console instance.");

        _sessions.removeFirstSwapLast(session);
        _allocator.freeT(session);
    }

    // TODO: don't like this API, it should be a method of Session...
    CommandState execute(Session session, const(char)[] cmdLine, out Variant result)
    {
        assert(session.current_command is null, "TODO: gotta do something about concurrent command execution...");

        Scope s = session._cur_scope;

        // TODO: reorg this code to stash context and run script...
        try
        {
            Array!ScriptCommand cmds = parse_commands(cmdLine);
            if (cmds.empty)
                return null;

            if(cmds[0].command.front_is('/'))
                s = get_root();

            Context ctx = Context(session, s, cmds.move);
            // TODO: return context to caller...

            return ctx.execute(session, s, result);
        }
        catch (Exception e)
        {
            // something went wrong
            return null;
        }
    }


    /// Request auto-completion for the given incomplete command line string.
    /// \param cmdLine
    ///  A command line string to attempt completion.
    /// \returns A new command line with the attempted auto-completion applied. If no completion was applicable, the result is `cmdLine` as given.
    MutableString!0 complete(const(char)[] cmdLine, Scope _cur_scope)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            size_t i = 0;
            while (i < cmdLine.length && (cmdLine[i] == ' ' || cmdLine[i] == '\t'))
                 ++i;
            if (i < cmdLine.length && cmdLine[i] == '/')
                _cur_scope = root;
            return _cur_scope.complete(cmdLine[i .. $]).insert(0, cmdLine[0 .. i]);
        }
    }

    /// Suggest a list of completion terms for the current incomplete command line.
    /// If a command line tail does not end on whitespace, the tail is taken to be a partially typed arguments, and filters the possible arguments by the partial prefix.
    /// \param cmdLine
    ///  A command line string to analyse for auto-complete suggestions.
    /// \returns A filtered list of possible completion terms.
    Array!String suggest(const(char)[] cmdLine, Scope _cur_scope)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            size_t i = 0;
            while (i < cmdLine.length && (cmdLine[i] == ' ' || cmdLine[i] == '\t'))
                ++i;
            if (i < cmdLine.length && cmdLine[i] == '/')
            {
                _cur_scope = root;
                ++i;
                while (i < cmdLine.length && (cmdLine[i] == ' ' || cmdLine[i] == '\t'))
                    ++i;
            }
            return _cur_scope.suggest(cmdLine[i .. $]);
        }
    }

    void register_command(const(char)[] _scope, Command command)
    {
        Scope s = create_scope(_scope);
        s.add_command(command);
    }

    void register_commands(const(char)[] _scope, Command[] commands)
    {
        Scope s = create_scope(_scope);
        foreach (cmd; commands)
            s.add_command(cmd);
    }

    void register_command(alias method, Instance)(const(char)[] _scope, Instance instance, const(char)[] commandName = null)
    {
        // TODO: put this back in to tell users how to get the signature right!
//        alias Fun = typeof(method)*;
//        static assert(is(Fun : R function(Session, A) nothrow @nogc, R, A...), typeof(method).stringof ~ " must be nothrow @nogc!");

        return register_command(_scope, FunctionCommand.create!method(this, instance, commandName));
    }

    void register_collection(Type)(string _scope, ref Collection!Type collection)
    {
        pragma(inline, true);

        ref Collection!Type* c = collection_for!Type();
        debug assert(c is null, "Collection has been registered before!");
        c = &collection;

        g_app.register_collection(*c, _scope);

        register_collection_impl(_scope, collection);
    }
    private void register_collection_impl(string _scope, ref BaseCollection collection)
    {
        import manager.console.collection_commands;

        Scope s = create_scope(_scope);
        s.add_collection_commands(collection);
    }

    void unregister_command(const(char)[] _scope, const(char)[] command)
    {
        Scope s = cast(Scope)find_command(_scope);
        assert(s !is null, tconcat("No scope: ", _scope));

        assert(false);
        // TODO
    }

    void unregister_commands(const(char)[] _scope, const(char)[][] commands)
    {
        Scope s = cast(Scope)find_command(_scope);
        assert(s !is null, tconcat("No scope: ", _scope));

        foreach (cmd; commands)
        {
            assert(false);
            // TODO
        }
    }




    void add_command(Command command, Scope parent)
    {
        parent.add_command(command);
    }

    Command find_command(const(char)[] cmdPath)
    {
        Scope s = get_root();
        Command cmd = null;

        if (cmdPath.front_is('/'))
        {
            cmdPath = cmdPath[1..$];
            s = get_root();
        }

        while (!cmdPath.empty)
        {
            if (s is null)
                return null;

            if (cmdPath.front_is(".."))
            {
                s = s._parent;
                cmd = s;
                if (cmdPath.length == 2)
                    return cmd;
                else if (cmdPath[2] != '/')
                    return null;
                cmdPath = cmdPath[3..$];
            }
            else
            {
                const(char)[] identifier = cmdPath.take_identifier;
                if (identifier.empty)
                    return null;
                cmd = s.get_command(identifier);
                if (!cmd)
                    return null;
                if (cmdPath.empty)
                    break;
                if (cmdPath[0] != '/')
                    return null;
                cmdPath = cmdPath[1..$];
                s = cast(Scope)cmd;
            }
        }
        return cmd;
    }

    Scope create_scope(const(char)[] path)
    {
        assert(path.front_is('/'), "Scope path must be root relative, ie: /path/to/scope");
        path = path[1..$];

        Scope s = get_root();

        while (!path.empty)
        {
            // check for child
            const(char)[] identifier = path.take_identifier;
            assert(!identifier.empty, "Invalid scope idenitifier");

            Command cmd = s.get_command(identifier);
            if (!cmd)
            {
                import urt.mem.string : addString;
                Scope newScope = _allocator.allocT!Scope(this, String(identifier.addString));
                s.add_command(newScope);
                s = newScope;
            }
            else
            {
                s = cast(Scope)cmd;
                assert(s !is null, "Command already exists, is not a Scope.");
            }

            if (!path.empty)
            {
                assert(path[0] == '/', "Expected Scope separator");
                assert(path.length > 1, "Expected Scope identifier");
                path = path[1..$];
            }
        }

        return s;
    }

package:
    NoGCAllocator _allocator;
    NoGCAllocator _tempAllocator;

    String _identifier;
    String _prompt;

    Map!(String, Command) _commands;
//    HashSet!Session _sessions;
    Array!Session _sessions;

    Console* _next_console_instance = null;
}


bool is_separator(char c)
{
    return c == ' ' || c == '\t';
}

MutableString!0 get_completion_suffix(const(char)[] token_start, ref const Array!String tokens)
{
    MutableString!0 result;
    if (tokens.length == 0)
        return result;
    if (tokens.length == 1)
    {
        // only one token; we'll emit the token completion, and the following space
        result = tokens[0][token_start.length .. tokens[0].length];
        result ~= ' ';
    }
    else
    {
        // we emit as many characters are common between all tokens
        size_t offset = token_start.length;
        while (offset < tokens[0].length)
        {
            char c = tokens[0][offset];
            bool same = true;
            for (size_t i = 1; i < tokens.length; ++i)
            {
                if (offset >= tokens[i].length || tokens[i][offset] != c)
                {
                    same = false;
                    break;
                }
            }
            if (!same)
                break;
            ++offset;
        }
        result = tokens[0][token_start.length .. offset];
    }
    return result;
}


private:

__gshared Console* g_console_instances = null;
