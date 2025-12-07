# OpenWatt Test Harness

Python-based test harness for testing OpenWatt runtime via telnet console interface.

## Quick Start

For interactive testing (recommended):
```bash
python test/test_session.py
```

For quick one-off tests:
```bash
python test/test_runner.py --quick
```

## Files

- **test_session.py** - Interactive REPL for sequential command testing
- **test_runner.py** - Quick test runner with predefined scenarios
- **test_harness.py** - Core library (OpenWattProcess, OpenWattConsole, TestRunner)
- **test_suite.json** - Example test suite definition
- **test_examples.py** - Usage examples
- **test_harness_features.md** - Error handling documentation
- **TEST_WORKFLOW.md** - Complete workflow guide

## Interactive Testing (Recommended)

Start a persistent session and send commands interactively:

```bash
python test/test_session.py

openwatt> /device/print
  [1234 chars, 0.85s] ...
  [PASS] no error

openwatt> .show 20           # Show first 20 lines
openwatt> .save output.txt   # Save to file
openwatt> /stream/tcp-client/print

openwatt> .exit
```

### REPL Commands

| Command | Description |
|---------|-------------|
| `/command args` | Send OpenWatt console command |
| `.show [n]` | Show last response (optional: first n lines) |
| `.save file` | Save last response to file |
| `.history` | Show command history |
| `.restart` | Restart OpenWatt |
| `.exit` | Exit session |

## Quick Testing

For one-off tests without interactive mode:

```bash
# Run basic test suite
python test/test_runner.py --basic

# Query devices and save output
python test/test_runner.py --devices

# Quick device print
python test/test_runner.py --quick
```

## Components

### TestSession
Persistent test session for sequential command testing:
- Start OpenWatt once
- Send commands interactively
- Analyze responses between commands
- Built-in validation (expect_contains, expect_no_error, etc.)

### OpenWattProcess
Manages OpenWatt binary lifecycle:
- Starts/stops process
- Detects crashes
- Captures output for diagnostics
- Reports exit codes

### OpenWattConsole
Telnet client for OpenWatt console (port 23):
- Connects with retry logic
- Sends commands
- Captures responses
- Handles Unicode

### TestRunner
Executes test suites with assertions:
- Runs multiple tests sequentially
- Validates with assertions (contains, regex, min_length)
- Reports pass/fail results
- Detects crashes mid-test

## Error Handling

The harness automatically detects:
- **Startup failures** - Process crashes during initial 6s delay
- **Mid-test crashes** - Detects if process dies between commands
- **Connection failures** - Reports why telnet connection failed
- **Output capture** - Saves last 50 lines for crash analysis

See [test_harness_features.md](test_harness_features.md) for details.

## Documentation

- **TEST_WORKFLOW.md** - Complete workflow guide with examples
- **test_harness_features.md** - Error handling and crash detection
- **test_examples.py** - Programmatic usage examples

## For Claude Code

A Claude Code skill is available at `.claude/skills/test-runtime.md` that provides guidance for automated testing.
