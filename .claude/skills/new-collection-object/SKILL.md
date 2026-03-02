---
name: new-collection-object
description: Boilerplate and patterns for creating new Collection-managed runtime objects (Streams, Interfaces, Protocol components). Use when adding a new managed object type.
---

# new-collection-object

Create a new Collection-managed runtime object in the OpenWatt codebase. This skill generates the boilerplate for objects managed by the Collection system (Streams, Interfaces, Protocol components, etc.).

## Usage

When the user asks to create a new Collection-managed object, use this skill to guide the implementation. Ask the user for:

1. **Object type**: Stream, Interface, Protocol client/server, or other
2. **Module name**: e.g., "mqtt", "modbus", "tcp", "serial"
3. **Class name**: e.g., "MQTTBroker", "HTTPServer", "CANInterface"
4. **Properties**: List of properties with types and descriptions
5. **Base class**: Usually Stream, BaseInterface, or BaseObject

## Boilerplate Patterns

### 1. File Structure

All Collection-managed objects follow this structure:

```d
module [layer].[category].[module];

// Standard imports
import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;
// ... other urt imports as needed

import manager;
import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

// Layer-specific imports
public import [layer].[category];  // e.g., router.stream, router.iface

nothrow @nogc:

// Enums/structs as needed
enum YourEnum : ubyte
{
    Value1,
    Value2,
}

// Main class
class YourObject : BaseClass
{
    __gshared Property[N] Properties = [ Property.create!("prop1", prop1)(),
                                         Property.create!("prop2", prop2)(),
                                         /* ... */ ];
nothrow @nogc:

    alias TypeName = StringLit!"type-name";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!YourObject, name.move, flags);
    }

    // Properties...
    [property implementations]

    // API...
    override bool validate() const pure
    {
        // Validate configuration
        return true;
    }

    override CompletionStatus startup()
    {
        // Initialize resources
        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        // Clean up resources
        return CompletionStatus.Complete;
    }

    override void update()
    {
        // Per-frame processing
    }

private:
    // Member variables
}

// Module class
class YourModule : Module
{
    mixin DeclareModule!"[layer].[module]";
nothrow @nogc:

    Collection!YourObject objects;

    override void init()
    {
        g_app.console.registerCollection("/[category]/[type]", objects);
    }

    override void update()
    {
        objects.update_all();
    }
}
```

### 2. Property Declaration Patterns

**The Properties Array (REQUIRED):**
```d
__gshared Property[N] Properties = [ Property.create!("prop-name", prop_name)(),
                                     Property.create!("other-prop", other_prop)(),
                                     /* exactly N properties */ ];
```

**Mutually Exclusive Properties:**

When properties represent different modes/options where only one should be active, track which is set internally rather than validating mutual exclusion:

```d
void mode_a(TypeA value)
{
    if (_mode_a == value)
        return;
    _mode_a = value;
    _active_mode = Mode.A;  // Track which mode is active
    restart();
}

void mode_b(TypeB value)
{
    if (_mode_b == value)
        return;
    _mode_b = value;
    _active_mode = Mode.B;  // Overwrite previous mode
    restart();
}

// In validate(), check that one mode is set
override bool validate() const
{
    return _active_mode != Mode.None;
}
```

**Property Getter/Setter Patterns:**

**Simple value type:**
```d
// Getter
ushort port() const pure
    => _port;

// Setter
void port(ushort value)
{
    if (_port == value)
        return; // early out is there is an advantage
    _port = value;
    restart();  // Trigger re-initialization if required
}
```

**String/complex type:**
```d
// Getter
ref const(String) device() const pure
    => _device;

// Setter with validation (returns StringResult)
StringResult device(String value)
{
    if (!value)
        return StringResult("device cannot be empty");
    if (_device == value)
        return StringResult.success;
    _device = value.move;
    restart();
    return StringResult.success;
}
```

**Enum type:**
```d
Parity parity() const pure
    => _parity;

void parity(Parity value)
{
    if (_parity == value)
        return;
    _parity = value;
    restart();
}
```

**Multiple overloads (type conversion):**
```d
void port(WellKnownPort value)
    => port(cast(ushort)value);

void port(ushort value)
{
    if (_port == value)
        return;
    _port = value;
    restart();
}
```

**ObjectRef property (reference to another Collection object):**
```d
// Getter
inout(Stream) stream() inout pure
    => _stream;

// Setter
StringResult stream(Stream value)
{
    if (!value)
        return StringResult("stream cannot be null");
    if (_stream is value)
        return StringResult.success;
    _stream = value;
    restart();
    return StringResult.success;
}

private:
    ObjectRef!Stream _stream;
```

### 3. State Machine Methods

**validate() - Configuration Validation**

Return `true` if configuration is valid:

```d
override bool validate() const pure
{
    // Check required properties are set
    if (_device.empty)
        return false;

    // Check valid ranges/combinations
    if (_baud_rate < 300 || _baud_rate > 115200)
        return false;

    // Check dependencies
    if (_stream.get() is null)
        return false;

    return true;
}
```

**startup() - Resource Initialization**

Initialize resources. Return:
- `CompletionStatus.Complete` - Success
- `CompletionStatus.Continue` - Still initializing, call again next frame
- `CompletionStatus.Error` - Failed, will retry with exponential backoff

```d
override CompletionStatus startup()
{
    // Async resolution example
    if (_host)
    {
        AddressInfo addrInfo;
        addrInfo.family = AddressFamily.ipv4;
        AddressInfoResolver results;
        get_address_info(_host, null, &addrInfo, results);
        if (!results.next_address(addrInfo))
            return CompletionStatus.Continue;  // Not ready yet
        _address = addrInfo.address;
    }

    // Resource creation with error handling
    Result r = create_resource(_handle);
    if (!r)
    {
        writeError(type, " '", name, "' - failed to create resource: ", r);
        return CompletionStatus.Error;  // Will retry with backoff
    }

    // Initialize state
    _initialized = true;

    writeInfo(type, " '", name, "' started successfully");
    return CompletionStatus.Complete;
}
```

**shutdown() - Resource Cleanup**

Clean up all resources. **Must not fail**. Called repeatedly while in `State.Stopping` (NOT `update()`).

Return `CompletionStatus.Continue` to continue shutdown asynchronously:

```d
override CompletionStatus shutdown()
{
    // For async/cancellable resources, request cancellation and wait
    if (has_pending_operations())
    {
        request_cancellation();
        poll_for_completion();

        if (still_waiting())
            return CompletionStatus.Continue;  // Will be called again
    }

    // Close handles/sockets
    if (_handle != invalid_handle)
    {
        close_handle(_handle);
        _handle = invalid_handle;
    }

    // Clear state
    _initialized = false;

    // Destroy if temporary
    if (_flags & ObjectFlags.Temporary)
        destroy();

    return CompletionStatus.Complete;
}
```

**update() - Per-Frame Processing**

Called every frame while Running:

```d
override void update()
{
    // Check connection status
    if (!is_connected())
    {
        restart();
        return;
    }

    // Process incoming data
    ubyte[4096] buffer;
    ptrdiff_t received = read(buffer);
    if (received > 0)
        process_data(buffer[0..received]);

    // Update internal state
    _last_activity = getTime();
}
```

### 4. Constructor Pattern

**For Streams (with StreamOptions):**
```d
this(String name, ObjectFlags flags = ObjectFlags.None, StreamOptions options = StreamOptions.None)
{
    super(collection_type_info!YourStream, name.move, flags, options);
}
```

**For Interfaces (with InterfaceOptions):**
```d
this(String name, ObjectFlags flags = ObjectFlags.None, InterfaceOptions options = InterfaceOptions.None)
{
    super(collection_type_info!YourInterface, name.move, flags, options);
}
```

**For other BaseObject subclasses:**
```d
this(String name, ObjectFlags flags = ObjectFlags.None)
{
    super(collection_type_info!YourObject, name.move, flags);
}
```

### 5. TypeName Requirement

Every Collection-managed class needs:

```d
alias TypeName = StringLit!"type-name";
```

This determines:
- Console command path: `/stream/type-name`, `/interface/type-name`
- Default object naming
- Type identification in logs

**Examples:**
- `StringLit!"tcp"` → `/stream/tcp-client`
- `StringLit!"serial"` → `/stream/serial`
- `StringLit!"modbus"` → `/interface/modbus`
- `StringLit!"mqtt-broker"` → `/protocol/mqtt/broker`

### 6. Module Class Pattern

```d
class YourModule : Module
{
    mixin DeclareModule!"layer.module";
nothrow @nogc:

    // Collections
    Collection!YourStream streams;
    Collection!YourInterface interfaces;

    // Non-collection objects (if any)
    Map!(const(char)[], YourClient) clients;

    override void init()
    {
        // Register collections with console
        g_app.console.registerCollection("/stream/your-type", streams);
        g_app.console.registerCollection("/interface/your-type", interfaces);
    }

    override void pre_update()
    {
        // Update all collection objects
        streams.update_all();
        interfaces.update_all();
    }

    override void update()
    {
        // Update non-collection objects
        foreach(client; clients.values)
            client.update();
    }

    override void post_update()
    {
        // Post-processing if needed
    }
}
```

### 7. Module Registration

Add to `src/manager/plugin.d` in `register_modules()`:

```d
void register_modules(Application app)
{
    // ... existing modules ...

    import your.module.path;
    register_module!(your.module.path)(app);
}
```

## Common Patterns

### ObjectRef Usage

When referencing other Collection-managed objects:

```d
private:
    ObjectRef!Stream _stream;
    ObjectRef!BaseInterface _interface;

// Property
inout(Stream) stream() inout pure
    => _stream;
StringResult stream(Stream value)
{
    if (!value)
        return StringResult("stream cannot be null");
    _stream = value;
    restart();
    return StringResult.success;
}

// Check in validate()
override bool validate() const pure
{
    return _stream.get() !is null;
}

// Use in methods
override CompletionStatus startup()
{
    if (!_stream)
        return CompletionStatus.Error;

    // Use _stream like a pointer
    ptrdiff_t bytes = _stream.read(buffer);
    // ...
}
```

### Subscriber Pattern

To be notified of events:

```d
override CompletionStatus startup()
{
    // Subscribe to state changes
    _interface.subscribe(&interface_state_handler);

    return CompletionStatus.Complete;
}

override CompletionStatus shutdown()
{
    // Always unsubscribe
    if (_interface)
        _interface.unsubscribe(&interface_state_handler);

    return CompletionStatus.Complete;
}

void interface_state_handler(BaseObject obj, StateSignal signal)
{
    if (signal == StateSignal.Online)
    {
        // Interface came online
        restart();
    }
    else if (signal == StateSignal.Offline)
    {
        // Interface went offline
    }
}
```

## Required Imports

**Often needed:**
```d
import urt.lifetime;       // move()
import urt.log;            // writeInfo, writeError, writeDebug
import urt.string;         // String type
import urt.time;           // getTime, MonoTime, SysTime, Duration

import manager;            // Application, g_app
import manager.base;       // BaseObject, ObjectFlags
import manager.collection; // Collection, collection_type_info
import manager.console;    // Console registration
import manager.plugin;     // Module, DeclareModule
```

**Common additional imports:**
```d
import urt.array;          // Array container
import urt.conv;           // Type conversions
import urt.map;            // Map container
import urt.meta.nullable;  // Nullable!T
import urt.result;         // Result, StringResult
import urt.string.format;  // tconcat, format
import urt.variant;        // Variant
```

**Layer-specific:**
```d
// Streams
public import router.stream;

// Interfaces
public import router.iface;

// Sockets
import urt.io;
import urt.socket;
```

## Checklist

When creating a new Collection-managed object, ensure:

- [ ] File is in correct location: `src/[layer]/[category]/[module].d`
- [ ] Module declaration at top: `module [layer].[category].[module];`
- [ ] All required imports included
- [ ] `nothrow @nogc:` attribute block after imports
- [ ] `__gshared Property[N]` array with exact count
- [ ] `alias TypeName = StringLit!"name";` defined
- [ ] Constructor calls `super(collection_type_info!ThisType, name.move, flags, ...)`
- [ ] All properties have getter/setter implementations
- [ ] `validate()` checks all required configuration if required
- [ ] `startup()` handles async initialization correctly
- [ ] `shutdown()` cleans up all resources (cannot fail)
- [ ] `update()` processes per-frame logic
- [ ] Module class extends `Module`
- [ ] Module uses `mixin DeclareModule!"path";`
- [ ] Collections registered in `init()`
- [ ] `update_all()` called appropriately
- [ ] Module registered in `src/manager/plugin.d`

## Examples by Layer

### Stream Example (Router Layer)

```d
module router.stream.example;

import urt.lifetime;
import urt.log;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

public import router.stream;

nothrow @nogc:

class ExampleStream : Stream
{
    __gshared Property[2] Properties = [ Property.create!("host", host)(),
                                         Property.create!("timeout", timeout)() ];
nothrow @nogc:

    alias TypeName = StringLit!"example";

    this(String name, ObjectFlags flags = ObjectFlags.None, StreamOptions options = StreamOptions.None)
    {
        super(collection_type_info!ExampleStream, name.move, flags, options);
    }

    // Properties
    ref const(String) host() const pure
        => _host;
    StringResult host(String value)
    {
        if (!value)
            return StringResult("host cannot be empty");
        _host = value.move;
        restart();
        return StringResult.success;
    }

    uint timeout() const pure
        => _timeout;
    void timeout(uint value)
    {
        _timeout = value;
    }

    // Stream API implementation
    override bool validate() const pure
        => !_host.empty;

    override CompletionStatus startup()
    {
        writeInfo("Example stream starting: ", _host[]);
        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.Complete;
    }

    override void update()
    {
    }

    override ptrdiff_t read(void[] buffer)
    {
        return 0;
    }

    override ptrdiff_t write(const void[] data)
    {
        return 0;
    }

    override ptrdiff_t pending()
    {
        return 0;
    }

    override ptrdiff_t flush()
    {
        return 0;
    }

    override const(char)[] remoteName()
    {
        return _host[];
    }

private:
    String _host;
    uint _timeout = 5000;
}

class ExampleStreamModule : Module
{
    mixin DeclareModule!"stream.example";
nothrow @nogc:

    Collection!ExampleStream streams;

    override void init()
    {
        g_app.console.registerCollection("/stream/example", streams);
    }

    override void pre_update()
    {
        streams.update_all();
    }
}
```

### Interface Example (Router Layer)

```d
module router.iface.example;

import urt.lifetime;
import urt.log;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

public import router.iface;
public import router.stream;

nothrow @nogc:

class ExampleInterface : BaseInterface
{
    __gshared Property[1] Properties = [ Property.create!("stream", stream)() ];
nothrow @nogc:

    alias TypeName = StringLit!"example";

    this(String name, ObjectFlags flags = ObjectFlags.None, InterfaceOptions options = InterfaceOptions.None)
    {
        super(collection_type_info!ExampleInterface, name.move, flags, options);
    }

    // Properties
    inout(Stream) stream() inout pure
        => _stream;
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        _stream = value;
        restart();
        return null;
    }

    // Interface implementation
    override bool validate() const pure
        => _stream.get() !is null;

    override CompletionStatus startup()
    {
        writeInfo("Example interface starting");
        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.Complete;
    }

    override void update()
    {
    }

    override void transmit(Packet packet)
    {
        // Send packet via stream
    }

private:
    ObjectRef!Stream _stream;
}

class ExampleInterfaceModule : Module
{
    mixin DeclareModule!"iface.example";
nothrow @nogc:

    Collection!ExampleInterface interfaces;

    override void init()
    {
        g_app.console.registerCollection("/interface/example", interfaces);
    }

    override void pre_update()
    {
        interfaces.update_all();
    }
}
```

### Protocol Broker Example (Protocol Layer)

```d
module protocol.example;

import urt.lifetime;
import urt.log;
import urt.string;

import manager;
import manager.base;
import manager.collection;
import manager.plugin;

public import router.stream;

nothrow @nogc:

class ExampleBroker : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("stream", stream)(),
                                         Property.create!("max-clients", max_clients)() ];
nothrow @nogc:

    alias TypeName = StringLit!"example-broker";

    this(String name, ObjectFlags flags = ObjectFlags.None)
    {
        super(collection_type_info!ExampleBroker, name.move, flags);
    }

    // Properties
    inout(Stream) stream() inout pure
        => _stream;
    const(char)[] stream(Stream value)
    {
        if (!value)
            return "stream cannot be null";
        _stream = value;
        restart();
        return null;
    }

    uint max_clients() const pure
        => _max_clients;
    void max_clients(uint value)
    {
        _max_clients = value;
    }

    // Implementation
    override bool validate() const pure
        => _stream.get() !is null;

    override CompletionStatus startup()
    {
        writeInfo("Example broker starting");
        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.Complete;
    }

    override void update()
    {
    }

private:
    ObjectRef!Stream _stream;
    uint _max_clients = 10;
}

class ExampleProtocolModule : Module
{
    mixin DeclareModule!"protocol.example";
nothrow @nogc:

    Collection!ExampleBroker brokers;

    override void init()
    {
        g_app.console.registerCollection("/protocol/example/broker", brokers);
    }

    override void pre_update()
    {
        brokers.update_all();
    }
}
```

## Testing

After creating a new Collection-managed object:

1. **Build the project**: `make`
2. **Add console commands** to `conf/startup.conf`:
   ```
   /stream/example add name=test host=example.com
   /stream/example print
   /stream/example get name=test property=host
   ```
3. **Run and verify** the object starts correctly
4. **Check logs** for startup/shutdown messages
5. **Test state transitions** by modifying properties

## Common Mistakes

1. **Wrong Property count**: Array size must match exactly
   ```d
   // WRONG - says 2 but has 3 properties
   __gshared Property[2] Properties = [ ..., ..., ... ];

   // CORRECT
   __gshared Property[3] Properties = [ ..., ..., ... ];
   ```

2. **Missing TypeName**: Required for Collection objects
   ```d
   // MISSING - won't compile
   class MyStream : Stream { }

   // CORRECT
   class MyStream : Stream
   {
       alias TypeName = StringLit!"my-stream";
   }
   ```

3. **Not calling restart()**: Properties that aren't practical to apply at runtime should restart
   ```d
   // WRONG - change won't take effect
   void port(ushort value)
   {
       _port = value;
   }

   // CORRECT
   void port(ushort value)
   {
       _port = value;
       restart();
   }
   ```

4. **shutdown() can fail**: Must always succeed
   ```d
   // WRONG - might return Error
   override CompletionStatus shutdown()
   {
       if (!close_resource())
           return CompletionStatus.Error;
       return CompletionStatus.Complete;
   }

   // CORRECT - handle errors gracefully
   override CompletionStatus shutdown()
   {
       close_resource();  // Best effort
       _handle = invalid;
       return CompletionStatus.Complete;
   }
   ```

5. **Forgetting module registration**: Must register in plugin.d
   ```d
   // Add to src/manager/plugin.d:
   import your.new.module;
   register_module!(your.new.module)(app);
   ```
