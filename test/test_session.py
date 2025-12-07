#!/usr/bin/env python3
"""
OpenWatt Test Session - Interactive testing for development

This module provides the TestSession class for persistent testing sessions.
For user-facing documentation, see test/TEST_WORKFLOW.md

Python API Usage:
    from test_session import TestSession

    # Basic usage
    session = TestSession()
    session.start()

    session.cmd('/device/print')
    session.expect_contains('energy-meter')
    session.expect_no_error()

    # Make code changes, rebuild...
    # Session stays alive!

    session.cmd('/stream/tcp-client/print')
    session.stop()

    # Or use context manager
    with TestSession() as session:
        session.cmd('/device/print')
        session.expect_no_error()
        session.save_response('output.txt')

API Reference:

    Start/Stop:
        session.start() -> bool          # Start OpenWatt & connect console
        session.stop()                   # Clean shutdown
        session.is_running() -> bool     # Check if alive (detects crashes)

    Execute Commands:
        session.cmd('/device/print')                    # Send command
        session.cmd('/device/print', delay=1.0)         # With custom delay

    Assertions (validates last response):
        session.expect_contains('text') -> bool         # Must contain
        session.expect_not_contains('text') -> bool     # Must not contain
        session.expect_no_error() -> bool               # No "Error:" present
        session.expect_regex(r'voltage: \\d+V') -> bool  # Regex match
        session.expect_min_length(500) -> bool          # Min chars

    Inspect Results:
        session.last_response                # Full response text (str)
        session.show_response()              # Print response
        session.show_response(20)            # Print first 20 lines
        session.save_response('file.txt')   # Save to file

    Utilities:
        session.history()            # Show command history
        session.quiet()              # Disable verbose output
        session.loud()               # Enable verbose output

Interactive REPL:
    Run this file directly to start interactive mode:
        python test/test_session.py

    REPL commands:
        /command args  - Send OpenWatt console command
        .show [n]      - Show last response (optional: first n lines)
        .save file     - Save last response to file
        .history       - Show command history
        .restart       - Restart OpenWatt
        .exit          - Exit session
"""

import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from test_harness import OpenWattProcess, OpenWattConsole
import re
import time
from typing import Optional, List, Dict, Any


class TestSession:
    """Persistent test session for iterative development"""

    def __init__(self, binary_path='bin/x86_64_debug/openwatt', auto_start=False):
        self.process: Optional[OpenWattProcess] = None
        self.console: Optional[OpenWattConsole] = None
        self.binary_path = binary_path
        self.last_response: str = ""
        self.command_history: List[Dict[str, Any]] = []
        self.verbose = True

        if auto_start:
            self.start()

    def start(self) -> bool:
        """Start OpenWatt and connect console"""
        if self.is_running():
            print("Session already running")
            return True

        print("Starting OpenWatt...")
        self.process = OpenWattProcess(self.binary_path)
        if not self.process.start():
            crash_info = self.process.get_crash_info()
            if crash_info:
                print(f"Failed to start (exit code {crash_info['exit_code']})")
                if crash_info['output_lines']:
                    print("Output:")
                    for line in crash_info['output_lines'][-20:]:
                        print(f"  {line}")
            return False

        self.console = self.process.get_console()
        if not self.console:
            print("Failed to get console")
            self.stop()
            return False

        print("Session ready!")
        return True

    def stop(self):
        """Stop session and clean up"""
        self.console = None  # Console is owned by process

        if self.process:
            self.process.stop()
            self.process = None

        print("Session stopped")

    def is_running(self) -> bool:
        """Check if session is still alive"""
        if not self.process or not self.console:
            return False

        if not self.process.is_running():
            crash_info = self.process.get_crash_info()
            print(f"[CRASH] OpenWatt crashed (exit code {crash_info['exit_code']})")
            if crash_info['output_lines']:
                print("Last output:")
                for line in crash_info['output_lines'][-10:]:
                    print(f"  {line}")
            return False

        return self.console.connected

    def cmd(self, command: str, delay: float = 0.5, timeout: float = 10.0) -> str:
        """Execute a command and return response

        Args:
            command: Command to execute
            delay: Initial delay before reading response
            timeout: Maximum time to wait for command completion (for latent commands)
        """
        if not self.is_running():
            raise RuntimeError("Session not running")

        if self.verbose:
            print(f"\n> {command}")

        start_time = time.time()
        self.last_response = self.console.send_command(command, read_delay=delay, timeout=timeout)
        elapsed = time.time() - start_time

        # Record in history
        self.command_history.append({
            'command': command,
            'response': self.last_response,
            'length': len(self.last_response),
            'elapsed': elapsed
        })

        if self.verbose:
            preview = self.last_response[:300].replace('\n', ' ')
            print(f"  [{len(self.last_response)} chars, {elapsed:.2f}s] {preview}...")

        return self.last_response

    def expect_contains(self, text: str, msg: Optional[str] = None) -> bool:
        """Validate last response contains text"""
        result = text in self.last_response
        if self.verbose:
            status = "[PASS]" if result else "[FAIL]"
            message = msg or f"contains '{text}'"
            print(f"  {status} {message}")
        return result

    def expect_not_contains(self, text: str, msg: Optional[str] = None) -> bool:
        """Validate last response does not contain text"""
        result = text not in self.last_response
        if self.verbose:
            status = "[PASS]" if result else "[FAIL]"
            message = msg or f"does not contain '{text}'"
            print(f"  {status} {message}")
        return result

    def expect_no_error(self) -> bool:
        """Validate no error in last response"""
        return self.expect_not_contains('Error:', 'no error')

    def expect_regex(self, pattern: str, msg: Optional[str] = None) -> bool:
        """Validate last response matches regex"""
        result = bool(re.search(pattern, self.last_response))
        if self.verbose:
            status = "[PASS]" if result else "[FAIL]"
            message = msg or f"matches /{pattern}/"
            print(f"  {status} {message}")
        return result

    def expect_min_length(self, length: int, msg: Optional[str] = None) -> bool:
        """Validate response is at least N characters"""
        result = len(self.last_response) >= length
        if self.verbose:
            status = "[PASS]" if result else "[FAIL]"
            message = msg or f"length >= {length} (got {len(self.last_response)})"
            print(f"  {status} {message}")
        return result

    def show_response(self, lines: Optional[int] = None):
        """Print the last response"""
        if lines:
            response_lines = self.last_response.split('\n')
            for line in response_lines[:lines]:
                print(line)
            if len(response_lines) > lines:
                print(f"... ({len(response_lines) - lines} more lines)")
        else:
            print(self.last_response)

    def save_response(self, filename: str):
        """Save last response to file"""
        with open(filename, 'w', encoding='utf-8') as f:
            f.write(self.last_response)
        if self.verbose:
            print(f"  Saved to {filename}")

    def quiet(self):
        """Disable verbose output"""
        self.verbose = False

    def loud(self):
        """Enable verbose output"""
        self.verbose = True

    def history(self, count: int = 10):
        """Show command history"""
        print(f"\nCommand History (last {count}):")
        for i, entry in enumerate(self.command_history[-count:], 1):
            print(f"  {i}. {entry['command']}")
            print(f"     {entry['length']} chars, {entry['elapsed']:.2f}s")

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()


def main():
    """Interactive REPL mode"""
    print("=" * 60)
    print("OpenWatt Test Session - Interactive Mode")
    print("=" * 60)
    print()
    print("Commands:")
    print("  /command args  - Send OpenWatt command")
    print("  .show [n]      - Show last response (optional: first n lines)")
    print("  .save file     - Save last response to file")
    print("  .history       - Show command history")
    print("  .restart       - Restart OpenWatt")
    print("  .exit          - Exit session")
    print()

    session = TestSession()
    if not session.start():
        print("Failed to start session")
        return 1

    try:
        while True:
            try:
                line = input("\nopenwatt> ").strip()

                if not line:
                    continue

                # Meta commands
                if line == '.exit':
                    break
                elif line == '.history':
                    session.history()
                elif line.startswith('.show'):
                    parts = line.split()
                    lines = int(parts[1]) if len(parts) > 1 else None
                    session.show_response(lines)
                elif line.startswith('.save'):
                    parts = line.split(maxsplit=1)
                    if len(parts) < 2:
                        print("Usage: .save filename")
                    else:
                        session.save_response(parts[1])
                elif line == '.restart':
                    session.stop()
                    if not session.start():
                        print("Failed to restart")
                        break
                else:
                    # OpenWatt command
                    session.cmd(line)

            except KeyboardInterrupt:
                print("\nUse .exit to quit")
            except EOFError:
                break
            except Exception as e:
                print(f"Error: {e}")

    finally:
        session.stop()

    return 0


if __name__ == '__main__':
    sys.exit(main())