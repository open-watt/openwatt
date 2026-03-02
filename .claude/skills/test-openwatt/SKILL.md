---
name: test-openwatt
description: Testing and debugging OpenWatt — unit tests, runtime test harness, persistent REPL, and crash debugging workflows. Use when running or writing tests.
---

# OpenWatt Testing Skill

You are helping test and debug the OpenWatt application (the IoT/industrial communications router).

**CRITICAL**: When testing OpenWatt, you MUST use the test tools in the `test/` directory. DO NOT write raw Python code to test - the tools already exist and are more reliable.

## Two Types of Testing

OpenWatt has two distinct testing approaches:

### 1. Unit Tests (D Language `unittest` blocks)
**When to use**: Testing individual functions, data structures, parsing logic, etc.

**How to run**:
```bash
# ALWAYS clean when switching to unittest config
rm -rf obj bin

# Build with unittests enabled
make CONFIG=unittest

# Run the tests
./bin/x86_64_unittest/openwatt_test

# Verify success
./bin/x86_64_unittest/openwatt_test 2>&1 | grep "passed"
```

**Important notes**:
- D's unittest system **replaces main()** when built with `-unittest`
- Always `rm -rf obj bin` when switching between debug/unittest configs (makedeps issue)
- Success message: "N modules passed unittests"
- Exit code 3 may appear but doesn't necessarily indicate failure - check for "passed" message

**When to write unittests**:
- Testing parsing logic (e.g., Duration.fromString())
- Testing data structure operations (Array, Map, etc.)
- Testing utility functions
- Testing protocol encoding/decoding
- Any isolated logic that doesn't require the full runtime

### 2. Runtime Integration Tests (Python test harness)
**When to use**: Testing the full OpenWatt application with console commands, devices, protocols, etc.

**How to run**:
```bash
# Quick sanity check
python test/test_runner.py --quick

# Interactive testing
python test/test_session.py

# With crash debugging
python test/test_runner.py --basic --debug
```

**When to use runtime tests**:
- Testing console commands
- Testing device collection and data flow
- Testing protocol communication (Modbus, MQTT, etc.)
- Testing the full system integration
- Debugging crashes and runtime issues

## Choosing the Right Test Approach

| Scenario | Use Unit Tests | Use Runtime Tests |
|----------|---------------|-------------------|
| Added new parsing function | ✓ | |
| Modified Duration.fromString() | ✓ | |
| Added new console command | | ✓ |
| Changed device discovery | | ✓ |
| Fixed Modbus protocol bug | ✓ (for encoding) | ✓ (for integration) |
| Investigating a crash | | ✓ (with --debug) |
| Testing data structures | ✓ | |
| Testing cron scheduling | | ✓ |

## Available Test Tools (Runtime Tests)

The `test/` directory contains a test harness with **3 core capabilities**:

### 1. Quick Test - Fast one-off commands

```bash
# Default: /system/sysinfo (environment-independent, always works!)
python test/test_runner.py

# Custom commands
python test/test_runner.py "/device/print"
python test/test_runner.py "/system/sysinfo" "/stream/tcp-client/print"
```

**Use for:** Quick sanity checks, CI/CD, simple validation
**Output:** Saves to `test_output.txt` and `test_logs.txt`

### 2. JSON Test Suite - Sequential commands with assertions

Create a JSON file with test steps:
```json
[
  {
    "name": "Step 1: Check devices",
    "command": "/device/print",
    "assertions": [{"type": "no_error"}]
  },
  {
    "name": "Step 2: Check streams",
    "command": "/stream/tcp-client/print"
  }
]
```

Run with: `python test/test_harness.py --suite test_suite.json`

**Use for:** Regression tests, automated testing, repeatable test scenarios

### 3. Persistent REPL - Interactive investigation (Claude's primary method)

**Two ways to use the REPL:**

#### Method A: Python REPL (for humans, via stdin piping)
```bash
# Pipe commands to test_session.py
cat << 'EOF' | python test/test_session.py
/device/print
.show 30
/stream/tcp-client/print
.exit
EOF
```

#### Method B: Named Pipe REPL (for Claude, TRUE persistent session)

**Setup persistent background REPL:**
```bash
# Start OpenWatt with named pipe (runs in background)
cd /d/Code/monitor
rm -f /tmp/ow_stdin
mkfifo /tmp/ow_stdin
tail -f /tmp/ow_stdin | bin/x86_64_debug/openwatt.exe --interactive > /tmp/ow_stdout.txt 2> /tmp/ow_stderr.txt &
echo $! > /tmp/ow_pid.txt
sleep 3
```

**Send commands and read responses:**
```bash
# Send command
echo "/system/sysinfo" > /tmp/ow_stdin

# Wait and read response
sleep 1 && tail -10 /tmp/ow_stdout.txt

# Analyze output, think about next step...

# Send another command to SAME session
echo "/device/print" > /tmp/ow_stdin
sleep 1 && tail -50 /tmp/ow_stdout.txt

# Check logs separately
tail -20 /tmp/ow_stderr.txt | grep -i error
```

**Cleanup:**
```bash
# Stop the REPL
cat /tmp/ow_pid.txt | xargs kill
rm /tmp/ow_stdin /tmp/ow_stdout.txt /tmp/ow_stderr.txt /tmp/ow_pid.txt
```

**Key advantages of Method B:**
- ✅ ONE persistent OpenWatt session across multiple commands
- ✅ Think and analyze between each command
- ✅ Separate stdout (CLI responses) and stderr (logs)
- ✅ Full REPL workflow from shell commands
- ✅ Can check uptime to verify session persistence

## Test Files Reference

- **test/test_runner.py** - Quick tests and basic suite (feature #1)
- **test/test_harness.py** - JSON test suite runner (feature #2) + core API
- **test/test_session.py** - Python-based REPL (feature #3, Method A)
- **test/test_examples.py** - Usage pattern examples
- **test/README.md** - Complete documentation

## Test Workflow for Claude

### RECOMMENDED: Named Pipe REPL (Persistent Session)

**Step 1: Start persistent REPL in background**
```bash
# Binary path is cross-platform:
#   Windows: bin/x86_64_debug/openwatt.exe
#   Linux:   bin/x86_64_debug/openwatt
BINARY="bin/x86_64_debug/openwatt$([ "$(uname -s | grep -i mingw)" ] && echo .exe)"

rm -f /tmp/ow_stdin
mkfifo /tmp/ow_stdin
tail -f /tmp/ow_stdin | $BINARY --interactive > /tmp/ow_stdout.txt 2> /tmp/ow_stderr.txt &
echo $! > /tmp/ow_pid.txt
sleep 3  # Wait for startup
echo "REPL started with PID: $(cat /tmp/ow_pid.txt)"
```

**Step 2: Send first command and analyze**
```bash
# Send command
echo "/system/sysinfo" > /tmp/ow_stdin

# Read response
sleep 1 && tail -10 /tmp/ow_stdout.txt
```

**Step 3: Think and send next command**
```bash
# Based on analysis, send another command to SAME session
echo "/device/print" > /tmp/ow_stdin

# Read full device list
sleep 1 && tail -50 /tmp/ow_stdout.txt | head -40
```

**Step 4: Check logs separately**
```bash
# Check for errors or warnings
tail -20 /tmp/ow_stderr.txt | grep -i "error\|warn"
```

**Step 5: Continue investigating**
```bash
# Send more commands, each one building on previous insights
echo "/stream/tcp-client/print" > /tmp/ow_stdin
sleep 1 && tail -30 /tmp/ow_stdout.txt
```

**Step 6: Cleanup when done**
```bash
# Stop the REPL
cat /tmp/ow_pid.txt | xargs kill
rm /tmp/ow_stdin /tmp/ow_stdout.txt /tmp/ow_stderr.txt /tmp/ow_pid.txt
```

**Key Advantages:**
- ✅ TRUE persistent session - ONE OpenWatt process for all commands
- ✅ Think and analyze between each command
- ✅ Check uptime (`/system/sysinfo`) to verify session persistence
- ✅ Separate CLI output (stdout) from logs (stderr)
- ✅ Full REPL investigation workflow from shell commands

## Testing Best Practices for Claude

### CRITICAL RULES
1. **Check for unit tests** - If you modified code in a module that has `unittest` blocks, run them: `make CONFIG=unittest && ./bin/x86_64_unittest/openwatt_test`
2. **ALWAYS use the test tools** - Never write raw Python code to interact with OpenWatt
3. **Use `python test/test_runner.py --quick`** for simple runtime sanity checks
4. **Use `python test/test_session.py`** for interactive development testing
5. **Use `--debug` flag** when investigating crashes to get stack traces

### When to Run Unit Tests
Run unit tests if you modified code in modules that have `unittest` blocks:
- After changing parsing logic (e.g., Duration, argument parsing)
- After modifying data structures or algorithms
- After fixing bugs in modules with existing tests
- When user explicitly asks you to test your changes

**How to check**: Search the modified file for `unittest` blocks. If found, run the tests.

**Command**: `rm -rf obj bin && make CONFIG=unittest && ./bin/x86_64_unittest/openwatt_test 2>&1 | grep "passed"`

### Before Starting
- Check for background OpenWatt processes (BashOutput tool)
- Kill any hanging instances to free port 23

### During Testing
- **Use appropriate delays** - Complex commands may need 0.8-1.0s delay
- **Analyze each response** before sending next command
- **Save output to files** when dealing with large responses (>500 chars)
- **Check for "Error:" strings** in responses to detect command failures
- **Check for crashes** - session.is_running() detects if process died

### Crash Debugging (NEW!)
When investigating crashes, use the `--debug` flag:
```bash
python test/test_runner.py --basic --debug
```

This will:
- Run OpenWatt under CDB debugger (Windows Debugging Tools)
- Capture full stack traces on crash
- Save crash info to `crash_info.txt` with:
  - Exit code analysis
  - Stack trace with function names and addresses
  - Last output before crash

**NOTE**: Requires Windows Debugging Tools installed. If not found, falls back to normal mode.

### What to Report
- Show first ~20 lines of responses (not full dumps)
- Summarize device counts, error states
- Report crashes with:
  - Exit code (and hex value)
  - Stack trace (if --debug was used)
  - Last output before crash
- Save full output to files for user to review

### Efficient Testing Pattern
```bash
# BEST: Named pipe REPL - persistent session, think between commands
BINARY="bin/x86_64_debug/openwatt$([ "$(uname -s | grep -i mingw)" ] && echo .exe)"
mkfifo /tmp/ow_stdin
tail -f /tmp/ow_stdin | $BINARY --interactive > /tmp/ow_stdout.txt 2> /tmp/ow_stderr.txt &
echo $! > /tmp/ow_pid.txt
echo "/device/print" > /tmp/ow_stdin
# (analyze output from /tmp/ow_stdout.txt)
echo "/stream/tcp-client/print" > /tmp/ow_stdin
# (analyze output)
kill $(cat /tmp/ow_pid.txt)

# GOOD: Quick test for simple checks
python test/test_runner.py

# AVOID: Restarting for each command (slow, wastes time)
python test/test_runner.py   # Command 1
python test/test_runner.py   # Command 2 <- wasteful!
```

## Common Test Scenarios

### Verify System Startup
```bash
python test/test_runner.py --basic
```

### Check Device Data Collection
```bash
python test/test_runner.py --devices
cat test/test_output.txt
```

### Debug Console Commands
```bash
python test/test_session.py
# Then type commands interactively at the prompt
```

### Custom Test Suite
Create `test/test_suite.json` and run:
```bash
python test/test_harness.py --suite test/test_suite.json
```

## Troubleshooting

- **Connection refused**: OpenWatt not started or crashed during startup
  - Check `crash_info.txt` for details
  - Re-run with `--debug` flag to get stack trace
- **Connection reset**: OpenWatt crashed handling a command (possible bug)
  - Check `crash_info.txt` for stack trace
  - Re-run with `--debug` flag for detailed crash analysis
- **Timeout**: Command taking too long, increase delay
- **No output**: Command may not exist or wrong path
- **Debugger not found**: Windows Debugging Tools not installed
  - Install from Windows SDK
  - Or run without `--debug` flag (basic crash detection still works)

## When Testing Finishes

- Kill any running OpenWatt instances
- Clean up temporary output files if not needed
- Report test results with clear pass/fail status
- If tests fail, provide diagnostic information

## Key OpenWatt Console Commands

- `/device/print` - List all devices and their current state
- `/stream/tcp-client/print` - List TCP client streams
- `/interface/modbus/print` - List Modbus interfaces
- `/protocol/mqtt/broker/print` - MQTT broker info
- `/system` - Enter system scope

Remember: The console uses hierarchical paths like filesystem directories. Commands follow the pattern `/category/subcategory/command arguments`.