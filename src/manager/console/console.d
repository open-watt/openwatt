module manager.console.console;

import urt.algorithm : binary_search;
import urt.array;
import urt.log;
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

    String name;
    Scope* parent;
    const(CollectionTypeInfo)* collection_type;   // non-null on collection-host scopes

    @disable this(this);

    this(String name)
    {
        this.name = name.move;
    }

    BaseCollection collection() const
        => BaseCollection(collection_type);

    inout(Scope)[] sub_scopes() inout pure
        => _sub_ptr[0 .. _sub_len];

    inout(Command)[] commands() inout pure
        => _cmd_ptr[0 .. _cmd_len];

    Scope* find_scope(const(char)[] name)
    {
        foreach (ref s; sub_scopes)
            if (s.name[] == name[])
                return &s;
        return null;
    }

    Command find_command(const(char)[] name)
    {
        foreach (c; commands)
            if (c.name[] == name[])
                return c;
        return null;
    }

    alias get_command = find_command;

    Scope* descend(const(char)[] seg)
    {
        if (seg.front_is('/') || seg.front_is(':'))
            seg = seg[1..$];
        if (seg.length == 0)
            return &this;
        if (seg == "..")
            return parent;
        return find_scope(seg);
    }

package:
    Scope* _sub_ptr;
    Command* _cmd_ptr;
    ushort _sub_len;
    ushort _cmd_len;
}


struct Console
{
nothrow @nogc:

    Application appInstance;

    Scope* root;
    Scope* script_scope;

    this() @disable;
    this(this) @disable;

    this(Application appInstance, String identifier, NoGCAllocator allocator, NoGCAllocator tempAllocator = null)
    {
        this.appInstance = appInstance;
        _allocator = allocator;
        _tempAllocator = tempAllocator ? tempAllocator : allocator;
        _identifier = identifier;

        // TODO: this is not threadsafe! creating/destroying console instances should be threadsafe!
        assert(findConsole(identifier[]) is null, tconcat("Console '", identifier[], "' already exists!"));
        _next_console_instance = g_console_instances;
        g_console_instances = &this;

        _scopes.reserve(128);
        _commands.reserve(128);

        // [0] = root, [1] = script_scope. Both empty initially; sub-scope strips
        // anchor at index 2 (where the first sub-scope would go).
        push_root(String(null));   // root
        push_root(String(null));   // script_scope
        root = &_scopes[0];
        script_scope = &_scopes[1];
        root._sub_ptr = _scopes.ptr + 2;
        script_scope._sub_ptr = _scopes.ptr + 2;
        root._cmd_ptr = _commands.ptr;
        script_scope._cmd_ptr = _commands.ptr;

        RegisterBuiltinCommands(this);
    }

    ~this()
    {
        // TODO: proper cleanup
    }

    void update()
    {
        foreach (session; _sessions)
            if (session.is_attached)
                session.update();
    }

    const(char)[] identifier() => _identifier[];
    const(char)[] get_prompt() nothrow @nogc => _prompt[];

    String set_prompt(String prompt)
        => _prompt.swap(prompt);

    SessionType createSession(SessionType, Args...)(auto ref Args args)
        if (is(SessionType : Session))
        {
            SessionType session = _allocator.allocT!SessionType(this, forward!args);
            session.set_prompt(_prompt[]);
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

        Array!char source;
        source ~= cmdLine;

        Array!ScriptCommand cmds;
        try
        {
            const(char)[] text = source[];
            cmds = parse_commands(text);
        }
        catch (Exception e)
        {
            return null;
        }
        if (cmds.empty)
            return null;

        Context ctx = _allocator.allocT!Context(session, root, script_scope, source.move, cmds.move);
        auto state = ctx.update();
        if (state >= CommandCompletionState.finished)
        {
            result = ctx.result.move;
            _allocator.freeT(ctx);
            return null;
        }
        return ctx;
    }

    CommandState execute(Session session, ref const Script body_, out Variant result)
    {
        assert(session.current_command is null, "TODO: gotta do something about concurrent command execution...");

        if (body_.empty)
            return null;

        Context ctx = _allocator.allocT!Context(session, root, script_scope, body_, &session._session_locals, Context.FrameKind.function_);
        auto state = ctx.update();
        if (state >= CommandCompletionState.finished)
        {
            result = ctx.result.move;
            _allocator.freeT(ctx);
            return null;
        }
        return ctx;
    }

    bool execute_script(Session session, Array!char source)
    {
        assert(session.current_command is null, "TODO: gotta do something about concurrent command execution...");

        Array!ScriptCommand cmds;
        const(char)[] text = source[];
        const(char)[] text_orig = text;
        try
        {
            cmds = parse_commands(text);
        }
        catch (SyntaxError e)
        {
            size_t consumed = text_orig.length - text.length;
            uint line = 1, col = 1;
            foreach (i; 0 .. consumed)
            {
                if (text_orig[i] == '\n') { ++line; col = 1; }
                else ++col;
            }
            log_error("config", "parse error at line ", line, ", col ", col, ": ", e.message);
            return false;
        }
        catch (Exception e)
            assert(false, "parse_commands should only throw SyntaxError");

        if (cmds.empty)
            return true;

        Context ctx = _allocator.allocT!Context(session, root, script_scope, source.move, cmds.move);
        auto state = ctx.update();
        if (state >= CommandCompletionState.finished)
        {
            _allocator.freeT(ctx);
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
            return complete_in(search, cmdLine[i .. $], _cur_scope).insert(0, cmdLine[0 .. i]);
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
            return suggest_in(search, cmdLine[i .. $], _cur_scope);
        }
    }

    void register_command(const(char)[] _scope, Command command)
    {
        Scope* parent = create_scope(_scope);
        add_command(parent, command);
    }

    void register_commands(const(char)[] _scope, Command[] commands)
    {
        Scope* parent = create_scope(_scope);
        foreach (cmd; commands)
            add_command(parent, cmd);
    }

    void register_command(alias method, Instance)(const(char)[] _scope, Instance instance, const(char)[] commandName = null)
    {
        return register_command(_scope, FunctionCommand.create!method(this, instance, commandName));
    }

    void register_collection(Type)()
    {
        register_collection(collection_type_info!Type);
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
        assert(parent.find_command(name) is null, tconcat("Command already exists: ", name));
        assert(parent.find_scope(name) is null, tconcat("Name collides with sub-scope: ", name));

        // Collection scopes start out pointing at a shared side-array. The
        // first extension command forces a copy into _commands so the strip
        // can grow.
        if (in_side_array(parent._cmd_ptr))
            promote(parent);

        size_t parent_cmd_start = parent._cmd_ptr - _commands.ptr;
        size_t local_pos = binary_search!((Command c, const(char)[] n) => cmp(c.name[], n), true)(parent.commands, name);
        size_t K = parent_cmd_start + local_pos;

        insert_command(K, command);

        parent._cmd_ptr = _commands.ptr + parent_cmd_start;
        ++parent._cmd_len;
    }

    private bool in_side_array(const Command* p) const pure
        => p >= &_coll_cmds[0] && p < &_coll_cmds[0] + _coll_cmds.length;

    // Copy `parent`'s shared-strip entries to a fresh slice at the end of
    // _commands so the strip can be extended. Other scopes' _cmd_ptr that
    // already live in _commands get fixed up if the buffer reallocs.
    private void promote(Scope* parent)
    {
        Command* src = parent._cmd_ptr;
        ushort n = parent._cmd_len;

        Command* old_base = _commands.ptr;
        _commands.reserve(_commands.length + n);
        Command* base = _commands.ptr;

        if (base !is old_base)
        {
            foreach (ref Scope s; _scopes[])
            {
                if (s._cmd_ptr is null || in_side_array(s._cmd_ptr))
                    continue;
                size_t old_idx = s._cmd_ptr - old_base;
                s._cmd_ptr = base + old_idx;
            }
        }

        size_t start = _commands.length;
        for (size_t i = 0; i < n; ++i)
            _commands ~= src[i];

        parent._cmd_ptr = base + start;
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
            Scope* next = n.descend(seg);
            if (next is null && create && seg != "..")
                next = grow_scope(n, seg);
            n = next;
        }
        return n;
    }

    private Scope* grow_scope(Scope* parent, const(char)[] name)
    {
        import urt.mem.string : addString;

        debug assert(!_frozen, "Console.grow_scope after freeze()");

        Scope* old_base = _scopes.ptr;
        size_t parent_idx = parent - old_base;
        size_t parent_sub_start = parent._sub_ptr - old_base;
        size_t parent_sub_count = parent._sub_len;

        // find sorted position within the parent's strip
        size_t local_pos = binary_search!((ref Scope s, const(char)[] n) => cmp(s.name[], n), true)(parent.sub_scopes, name);
        size_t K = parent_sub_start + local_pos;

        _scopes.insertEmplace(K, String(name.addString));

        Scope* base = _scopes.ptr;

        // fix up all OTHER scopes' parent and _sub_ptr fields.
        // plus the inserting parent's _sub_ptr (which doesn't shift since
        // parent_idx < K, but we also need to extend its _sub_len).
        foreach (ref Scope s; _scopes[])
        {
            if (&s is &base[K])
                continue; // new scope: set explicitly below

            if (s.parent !is null)
            {
                size_t old_p = s.parent - old_base;
                s.parent = base + (old_p < K ? old_p : old_p + 1);
            }

            if (s._sub_ptr !is null)
            {
                size_t old_p = s._sub_ptr - old_base;
                s._sub_ptr = base + (old_p < K ? old_p : old_p + 1);
            }

            // Commands pointer just needs the (unchanged) _commands.ptr — pool
            // didn't move. But after a Scope-pool realloc, &s might have shifted
            // and we still hold the correct _cmd_ptr (it points into a different
            // pool).
        }

        Scope* fresh = &base[K];
        Scope* p = &base[parent_idx]; // parent_idx < K, so parent stayed put

        // restore parent's _sub_ptr (the loop incorrectly shifted it if its
        // old start was at K — empty strip / left-insert case) and extend.
        p._sub_ptr = base + parent_sub_start;
        ++p._sub_len;

        fresh.parent = p;
        size_t parent_new_end = parent_sub_start + parent_sub_count + 1;
        fresh._sub_ptr = base + parent_new_end;
        fresh._cmd_ptr = _commands.ptr + _commands.length;
        fresh._cmd_len = 0;

        if (base !is old_base)
        {
            root = &_scopes[0];
            script_scope = &_scopes[1];
        }

        return fresh;
    }

    private void insert_command(size_t K, Command cmd)
    {
        Command* old_base = _commands.ptr;
        _commands.insert(K, cmd);

        // fix up every Scope's _cmd_ptr that lives in _commands. Scopes
        // pointing into the shared side-array (collection scopes) are
        // untouched — the side-array isn't part of _commands.
        Command* base = _commands.ptr;
        foreach (ref Scope s; _scopes[])
        {
            if (s._cmd_ptr is null || in_side_array(s._cmd_ptr))
                continue;
            size_t old_idx = s._cmd_ptr - old_base;
            s._cmd_ptr = base + (old_idx < K ? old_idx : old_idx + 1);
        }
    }

    private void push_root(String name)
    {
        _scopes.emplaceBack(name.move);
    }

package:
    NoGCAllocator _allocator;
    NoGCAllocator _tempAllocator;

    String _identifier;
    String _prompt;

    Array!Scope _scopes;
    Array!Command _commands;
    Array!Session _sessions;

    Command[12] _coll_cmds;      // shared collection-op commands (lazy-init); see collection_commands.d

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


MutableString!0 complete_in(Scope* node, const(char)[] cmdLine, Scope* user_scope)
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
            if (Scope* sub = node.find_scope(name))
                r = complete_in(sub, cmdLine[j..$], user_scope);
            else if (Command cmd = node.find_command(name))
                r = cmd.complete(cmdLine[j..$], node, user_scope);
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
        foreach (ref Scope s; node.sub_scopes)
            if (s.name[].startsWith(cmdLine[i..j]))
                cmds ~= Cmd(s.name[], true);
        foreach (Command c; node.commands)
            if (c.name[].startsWith(cmdLine[i..j]))
                cmds ~= Cmd(c.name[], false);

        if (cmds.length == 0)
            return MutableString!0(cmdLine);
        if (cmds.length == 1)
            return complete_in(node, tconcat(cmdLine[0..i], cmds[0].name[], cmds[0].isScope && (i == 0 || cmdLine[0] == '/') ? '/' : ' '), user_scope);
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


Array!String suggest_in(Scope* node, const(char)[] cmdLine, Scope* user_scope)
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
            if (Scope* sub = node.find_scope(name))
            {
                size_t j = i;
                if (j < cmdLine.length && cmdLine[j] == '/')
                    ++j;
                while (j < cmdLine.length && is_whitespace(cmdLine[j]))
                    ++j;
                return suggest_in(sub, cmdLine[j..$], user_scope);
            }
            if (Command cmd = node.find_command(name))
            {
                size_t j = i;
                while (j < cmdLine.length && is_whitespace(cmdLine[j]))
                    ++j;
                return cmd.suggest(cmdLine[j..$], node, user_scope);
            }
            return Array!String();
        }

        Array!String r;
        foreach (ref Scope s; node.sub_scopes)
            if (s.name[].startsWith(cmdLine))
                r ~= s.name;
        foreach (Command c; node.commands)
            if (c.name[].startsWith(cmdLine))
                r ~= c.name;
        return r;
    }
}


private:

__gshared Console* g_console_instances = null;
