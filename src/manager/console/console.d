module manager.console.console;

import urt.algorithm : binary_search;
import urt.array;
import urt.log;
import urt.map;
import urt.mem;
import urt.string;
import urt.string.format;
import urt.time : MonoTime;
import urt.util;

import manager : g_app;
import manager.base : ObjectFlags;
import manager.collection;
import manager.console.builtin_commands;
import manager.console.command;
import manager.console.function_command;
import manager.console.session;
import manager.expression;

import router.stream : Stream;

nothrow @nogc:


Console* findConsole(const(char)[] identifier) nothrow @nogc
{
    Console* instance = g_console_instances;
    while (instance && instance._identifier != identifier[])
        instance = instance._next_console_instance;
    return instance;
}


struct Scope
{
nothrow @nogc:
    import manager.collection : BaseCollection, CollectionTypeInfo;

    enum ushort no_parent = 0xFFFF;

    const(CollectionTypeInfo)* collection_type;   // non-null on collection-host scopes

    // aliases the caller's memory: registration paths must be persistent (string literals)
    this(const(char)[] name)
    {
        assert(name.length <= ubyte.max, "Scope name too long");
        _name_ptr = name.ptr;
        _name_len = cast(ubyte)name.length;
    }

    const(char)[] name() const pure
        => _name_ptr[0 .. _name_len];

    BaseCollection collection() const
        => BaseCollection(collection_type);

    Scope* parent(ref Console console) pure
        => _parent == no_parent ? null : &console._scopes[_parent];

    Scope[] sub_scopes(ref Console console) pure
        => console._scopes[_sub_start .. _sub_start + _sub_len];

    Command[] commands(ref Console console) pure
        => console._commands[_cmd_start .. _cmd_start + _cmd_len];

    Scope* find_scope(ref Console console, const(char)[] name)
    {
        foreach (ref s; sub_scopes(console))
            if (s.name[] == name[])
                return &s;
        return null;
    }

    Command* find_command(ref Console console, const(char)[] name)
    {
        foreach (ref c; commands(console))
            if (c.name[] == name[])
                return &c;
        return null;
    }

    alias get_command = find_command;

    Scope* descend(ref Console console, const(char)[] seg)
    {
        if (seg.front_is('/') || seg.front_is(':'))
            seg = seg[1..$];
        if (seg.length == 0)
            return &this;
        if (seg == "..")
            return parent(console);
        return find_scope(console, seg);
    }

package:
    const(char)* _name_ptr;
    ubyte _name_len;
    ushort _parent = no_parent;
    ushort _sub_start;
    ushort _cmd_start;
    ushort _sub_len;
    ushort _cmd_len;
}


struct Console
{
nothrow @nogc:

    Application appInstance;

    this() @disable;
    this(this) @disable;

    this(Application appInstance, String identifier)
    {
        this.appInstance = appInstance;
        _identifier = identifier;

        // TODO: this is not threadsafe! creating/destroying console instances should be threadsafe!
        assert(findConsole(identifier[]) is null, tconcat("Console '", identifier[], "' already exists!"));
        _next_console_instance = g_console_instances;
        g_console_instances = &this;

        _scopes.reserve(128);
        _commands.reserve(128);

        // [0] = root, [1] = script_scope. Both empty initially; sub-scope strips
        // anchor at index 2 (where the first sub-scope would go).
        push_root();   // root
        push_root();   // script_scope
        root._sub_start = 2;
        script_scope._sub_start = 2;

        import manager.console.collection_commands : init_shared_commands;
        init_shared_commands(this);
        root._cmd_start = shared_cmd_count;
        script_scope._cmd_start = shared_cmd_count;

        RegisterBuiltinCommands(this);
    }

    Scope* root() pure
        => &_scopes[0];
    Scope* script_scope() pure
        => &_scopes[1];

    ~this()
    {
        if (g_console_instances is &this)
            g_console_instances = _next_console_instance;
        else
        {
            for (Console* p = g_console_instances; p !is null; p = p._next_console_instance)
            {
                if (p._next_console_instance is &this)
                {
                    p._next_console_instance = _next_console_instance;
                    break;
                }
            }
        }
    }

    const(char)[] identifier() => _identifier[];
    const(char)[] get_prompt() nothrow @nogc => _prompt[];

    String set_prompt(String prompt)
        => _prompt.swap(prompt);

    SessionType createSession(SessionType)(Stream stream = null)
        if (is(SessionType : Session))
        {
            auto sessions = Collection!Session();
            const(char)[] name = sessions.generate_name("session");
            CID id = sessions.allocate_id(name);
            if (!id)
                return null;

            enum flags = cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary);
            SessionType session = alloc!SessionType(id, flags, this);
            if (stream)
                session.stream(stream);
            sessions.add(session);
            session.do_update();
            return session;
        }

    void destroy_session(Session session)
    {
        assert(session._console is &this, "Session does not belong to this console instance.");
        session.request_destroy();
    }

    // TODO: don't like this API, it should be a method of Session...
    CommandState execute(Session session, const(char)[] cmdLine, out Variant result)
    {
        assert(session.current_command is null, "TODO: gotta do something about concurrent command execution...");

        Array!char source;
        source ~= cmdLine;

        const(char)[] text = source[];
        const(char)[] parse_error;
        Array!ScriptCommand cmds = parse_commands(text, parse_error);
        if (parse_error)
        {
            session.writef("Parse error at column {0}: {1}\n", source.length - text.length + 1, parse_error);
            return null;
        }
        if (cmds.empty)
            return null;

        Context ctx = alloc!Context(session, root, script_scope, source.move, cmds.move);
        auto state = ctx.update();
        if (state >= CommandCompletionState.finished)
        {
            result = ctx.result.move;
            free(ctx);
            return null;
        }
        return ctx;
    }

    CommandState execute(Session session, ref const Script body_, out Variant result)
    {
        assert(session.current_command is null, "TODO: gotta do something about concurrent command execution...");

        if (body_.empty)
            return null;

        Context ctx = alloc!Context(session, root, script_scope, body_, &session._session_locals, Context.FrameKind.function_);
        auto state = ctx.update();
        if (state >= CommandCompletionState.finished)
        {
            result = ctx.result.move;
            free(ctx);
            return null;
        }
        return ctx;
    }

    bool execute_script(Session session, Array!char source)
    {
        assert(session.current_command is null, "TODO: gotta do something about concurrent command execution...");

        const(char)[] text = source[];
        const(char)[] text_orig = text;
        const(char)[] parse_error;
        Array!ScriptCommand cmds = parse_commands(text, parse_error);
        if (parse_error)
        {
            size_t consumed = text_orig.length - text.length;
            uint line = 1, col = 1;
            foreach (i; 0 .. consumed)
            {
                if (text_orig[i] == '\n') { ++line; col = 1; }
                else ++col;
            }
            log_error("config", "parse error at line ", line, ", col ", col, ": ", parse_error);
            return false;
        }

        if (cmds.empty)
            return true;

        Context ctx = alloc!Context(session, root, script_scope, source.move, cmds.move);
        auto state = ctx.update();
        if (state >= CommandCompletionState.finished)
        {
            free(ctx);
            return true;
        }
        session.current_command = ctx;
        return true;
    }


    MutableString!0 complete(const(char)[] cmdLine, Scope* _cur_scope)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            size_t i = 0;
            while (i < cmdLine.length && (cmdLine[i] == ' ' || cmdLine[i] == '\t'))
                 ++i;
            Scope* search = _cur_scope;
            if (i < cmdLine.length && cmdLine[i] == '/')
                search = root;
            else if (i < cmdLine.length && cmdLine[i] == ':')
                search = script_scope;
            return complete_in(this, search, cmdLine[i .. $], _cur_scope).insert(0, cmdLine[0 .. i]);
        }
    }

    Array!String suggest(const(char)[] cmdLine, Scope* _cur_scope)
    {
        version (ExcludeAutocomplete)
            return null;
        else
        {
            size_t i = 0;
            while (i < cmdLine.length && (cmdLine[i] == ' ' || cmdLine[i] == '\t'))
                ++i;
            Scope* search = _cur_scope;
            if (i < cmdLine.length && (cmdLine[i] == '/' || cmdLine[i] == ':'))
            {
                search = (cmdLine[i] == '/') ? root : script_scope;
                ++i;
                while (i < cmdLine.length && (cmdLine[i] == ' ' || cmdLine[i] == '\t'))
                    ++i;
            }
            return suggest_in(this, search, cmdLine[i .. $], _cur_scope);
        }
    }

    void register_command(const(char)[] _scope, Command command)
    {
        Scope* parent = create_scope(_scope);
        add_command(parent, command);
    }

    void register_command(alias method, string command_name = null, Instance)(const(char)[] _scope, Instance instance)
    {
        register_command(_scope, Command(&function_command_desc!(method, command_name), cast(void*)instance));
    }

    void register_collection(Type)()
    {
        register_collection(collection_type_info!Type);

        static if (is(Type == CollectionRoot!Type) && is(Type : ActiveObject) &&
                   is(typeof((Type t) => t.heartbeat(MonoTime.init))))
        {
            g_app.register_heartbeat_handler((MonoTime now) { Collection!Type().heartbeat(now); });
        }
    }

    void unregister_command(const(char)[] _scope, const(char)[] command)
    {
        Scope* n = find_scope_path(_scope);
        assert(n !is null, tconcat("No scope: ", _scope));

        assert(false);
        // TODO
    }

    void freeze()
    {
        log_info("console", "registration complete: ", _scopes.length, " scopes, ", _commands.length, " commands");
        debug _frozen = true;
    }

    void add_command(Scope* parent, Command command)
    {
        debug assert(!_frozen, "Console.add_command after freeze()");
        const(char)[] name = command.name[];
        assert(parent.find_command(this, name) is null, tconcat("Command already exists: ", name));
        assert(parent.find_scope(this, name) is null, tconcat("Name collides with sub-scope: ", name));

        if (parent._cmd_start < shared_cmd_count)
            promote(parent);

        size_t local_pos = binary_search!((Command c, const(char)[] n) => cmp(c.name[], n), true)(parent.commands(this), name);
        size_t K = parent._cmd_start + local_pos;

        _commands.insert(K, command);
        foreach (ref Scope s; _scopes[])
        {
            if (&s !is parent && s._cmd_start >= K)
                ++s._cmd_start;
        }
        ++parent._cmd_len;
    }

    private void promote(Scope* parent)
    {
        size_t start = _commands.length;
        _commands.reserve(start + parent._cmd_len);
        foreach (i; 0 .. parent._cmd_len)
            _commands ~= _commands[parent._cmd_start + i];
        parent._cmd_start = cast(ushort)start;
    }

    Scope* find_scope_path(const(char)[] path) { return walk_path(path, false); }

    Scope* create_scope(const(char)[] path)
    {
        assert(path.front_is('/'), "Path must be root relative, ie: /path/to/scope");
        return walk_path(path, true);
    }

    private Scope* walk_path(const(char)[] path, bool create)
    {
        if (path.front_is('/'))
            path = path[1..$];

        Scope* n = root;
        while (!path.empty)
        {
            if (n is null)
                return null;
            const(char)[] seg = take_path_segment(path);
            if (seg.empty)
            {
                assert(!create, "Invalid path syntax");
                return null;
            }
            Scope* next = n.descend(this, seg);
            if (next is null && create && seg != "..")
                next = grow_scope(n, seg);
            n = next;
        }
        return n;
    }

    private Scope* grow_scope(Scope* parent, const(char)[] name)
    {
        debug assert(!_frozen, "Console.grow_scope after freeze()");

        // a scope always precedes its own strip, so parent_idx never shifts
        ushort parent_idx = cast(ushort)(parent - _scopes.ptr);

        // find sorted position within the parent's strip
        size_t local_pos = binary_search!((ref Scope s, const(char)[] n) => cmp(s.name[], n), true)(parent.sub_scopes(this), name);
        size_t K = parent._sub_start + local_pos;

        _scopes.insertEmplace(K, name);

        foreach (i, ref Scope s; _scopes[])
        {
            if (i == K)
                continue; // new scope: set explicitly below

            if (s._parent != Scope.no_parent && s._parent >= K)
                ++s._parent;

            // the parent's strip extends rather than shifts, even when anchored at K
            if (i != parent_idx && s._sub_start >= K)
                ++s._sub_start;
        }

        Scope* p = &_scopes[parent_idx];
        ++p._sub_len;

        Scope* fresh = &_scopes[K];
        fresh._parent = parent_idx;
        fresh._sub_start = cast(ushort)(p._sub_start + p._sub_len);
        fresh._cmd_start = cast(ushort)_commands.length;
        fresh._cmd_len = 0;

        return fresh;
    }

    private void push_root()
    {
        _scopes.emplaceBack(cast(const(char)[])null);
    }

package:
    String _identifier;
    String _prompt;

    // the shared collection-op strips; see collection_commands.d
    enum ushort shared_cmd_count = 12;

    Array!Scope _scopes;
    Array!Command _commands;

    debug bool _frozen = false;

    Console* _next_console_instance = null;

    void register_collection(const(CollectionTypeInfo)* type_info)
    {
        const(char)[] _scope = type_info.path[];
        debug assert(_scope !is null, "collection type must declare `enum path = \"...\";`");

        g_app.register_type(type_info, _scope);

        import manager.console.collection_commands;
        Scope* n = create_scope(_scope);
        add_collection_commands(this, n, BaseCollection(type_info));
    }
}


bool is_separator(char c)
    => c == ' ' || c == '\t';

const(char)[] take_path_segment(ref const(char)[] path)
{
    if (path.empty)
        return null;

    const(char)[] seg;
    if (path.length >= 2 && path[0..2] == "..")
    {
        seg = path[0..2];
        path = path[2..$];
    }
    else
    {
        seg = path.take_identifier;
        if (seg.empty)
            return null;
    }

    if (!path.empty)
    {
        if (path[0] != '/')
            return null;
        path = path[1..$];
    }
    return seg;
}

MutableString!0 get_completion_suffix(const(char)[] token_start, ref const Array!String tokens)
{
    MutableString!0 result;
    if (tokens.length == 0)
        return result;
    if (tokens.length == 1)
    {
        result = tokens[0][token_start.length .. tokens[0].length];
        result ~= ' ';
    }
    else
    {
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


MutableString!0 complete_in(ref Console console, Scope* node, const(char)[] cmdLine, Scope* user_scope)
{
    version (ExcludeAutocomplete)
        return MutableString!0(cmdLine);
    else
    {
        size_t i = 0;
        if (cmdLine.front_is('/') || cmdLine.front_is(':'))
            ++i;
        while (i < cmdLine.length && is_whitespace(cmdLine[i]))
            ++i;
        if (i < cmdLine.length && cmdLine[i] == '/')
            return MutableString!0(cmdLine);

        size_t j = i;
        while (j < cmdLine.length && !is_whitespace(cmdLine[j]) && cmdLine[j] != '/')
            ++j;

        if (j < cmdLine.length)
        {
            const(char)[] name = cmdLine[i..j];
            MutableString!0 r;
            if (Scope* sub = node.find_scope(console, name))
                r = complete_in(console, sub, cmdLine[j..$], user_scope);
            else if (Command* cmd = node.find_command(console, name))
                r = cmd.complete(console, cmdLine[j..$], node, user_scope);
            else
                return MutableString!0(cmdLine);
            return r.insert(0, cmdLine[0..j]);
        }

        struct Cmd
        {
            const(char)[] name;
            bool isScope;
        }
        Array!Cmd cmds;
        foreach (ref Scope s; node.sub_scopes(console))
            if (s.name[].startsWith(cmdLine[i..j]))
                cmds ~= Cmd(s.name[], true);
        foreach (ref Command c; node.commands(console))
            if (c.name[].startsWith(cmdLine[i..j]))
                cmds ~= Cmd(c.name[], false);

        if (cmds.length == 0)
            return MutableString!0(cmdLine);
        if (cmds.length == 1)
            return complete_in(console, node, tconcat(cmdLine[0..i], cmds[0].name[], cmds[0].isScope && (i == 0 || cmdLine[0] == '/') ? '/' : ' '), user_scope);
        size_t k = j-i;
        outer: for (; k < cmds[0].name.length; ++k)
        {
            for (size_t l = 1; l < cmds.length; ++l)
                if (k >= cmds[l].name.length || cmds[l].name[k] != cmds[0].name[k])
                    break outer;
        }
        return MutableString!0().concat(cmdLine[0..i], cmds[0].name[0 .. k]);
    }
}


Array!String suggest_in(ref Console console, Scope* node, const(char)[] cmdLine, Scope* user_scope)
{
    version (ExcludeAutocomplete)
        return Array!String();
    else
    {
        size_t i = 0;
        while (i < cmdLine.length && !is_whitespace(cmdLine[i]) && cmdLine[i] != '/')
            ++i;

        if (i < cmdLine.length)
        {
            const(char)[] name = cmdLine[0 .. i];
            if (Scope* sub = node.find_scope(console, name))
            {
                size_t j = i;
                if (j < cmdLine.length && cmdLine[j] == '/')
                    ++j;
                while (j < cmdLine.length && is_whitespace(cmdLine[j]))
                    ++j;
                return suggest_in(console, sub, cmdLine[j..$], user_scope);
            }
            if (Command* cmd = node.find_command(console, name))
            {
                size_t j = i;
                while (j < cmdLine.length && is_whitespace(cmdLine[j]))
                    ++j;
                return cmd.suggest(console, cmdLine[j..$], node, user_scope);
            }
            return Array!String();
        }

        Array!String r;
        foreach (ref Scope s; node.sub_scopes(console))
            if (s.name[].startsWith(cmdLine))
                r ~= String(MutableString!0(s.name));
        foreach (ref Command c; node.commands(console))
            if (c.name[].startsWith(cmdLine))
                r ~= String(MutableString!0(c.name));
        return r;
    }
}


private:

__gshared Console* g_console_instances = null;


unittest
{

    // Heap-allocated and leaked: Console registers itself in a __gshared list
    // and never removes itself, so the address must outlive the test.
    Console* console = alloc!Console(null, StringLit!"test.console");

    Scope* s = console.create_scope("/system/test");
    assert(console.find_scope_path("/system/test") is s);
    assert(s.parent(*console).name[] == "system");
    assert(s.parent(*console).parent(*console) is console.root);

    Scope* a = console.create_scope("/system/apple");
    assert(console.find_scope_path("/system/test").name[] == "test");
    assert(console.find_scope_path("/system/apple") is a);

    assert(console.script_scope.find_command(*console, "put") !is null);
    assert(console.root.find_command(*console, "put") is null);

    MutableString!0 c = console.complete(":pu", console.root);
    assert(c[].startsWith(":put"));

    Array!String suggestions = console.suggest(":r", console.root);
    assert(suggestions.length == 2);   // return, run
}
