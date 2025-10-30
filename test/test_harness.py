#!/usr/bin/env python3
"""
OpenWatt Test Harness
Provides utilities for testing OpenWatt via --interactive mode (stdin/stdout)
"""

import time
import sys
import subprocess
import json
import platform
import threading
import queue
from pathlib import Path
from typing import Optional, List, Dict, Any, Tuple
import re


class OpenWattConsole:
    """Manages communication with OpenWatt interactive console via stdin/stdout"""

    def __init__(self, process: subprocess.Popen):
        self.process = process
        self.connected = True
        self.output_queue = queue.Queue()
        self.reader_thread = None
        self._start_reader_thread()

    def _start_reader_thread(self):
        """Start background thread to read stdout"""
        def reader():
            try:
                for line in iter(self.process.stdout.readline, ''):
                    if not line:
                        break
                    self.output_queue.put(line)
            except Exception as e:
                self.output_queue.put(None)  # Signal error

        self.reader_thread = threading.Thread(target=reader, daemon=True)
        self.reader_thread.start()

    def send_command(self, cmd: str, read_delay=0.5, timeout=10.0) -> str:
        """Send a command and return the response

        Args:
            cmd: Command to send
            read_delay: Initial delay before reading response
            timeout: Maximum time to wait for command completion (for latent commands)
        """
        if not self.connected or not self.process or not self.process.stdin:
            raise RuntimeError("Not connected to console")

        try:
            # Clear any pending output (startup messages, etc)
            while not self.output_queue.empty():
                try:
                    self.output_queue.get_nowait()
                except queue.Empty:
                    break

            # Send command
            self.process.stdin.write(cmd + '\n')
            self.process.stdin.flush()

            # Wait for response (longer delay to let command execute)
            time.sleep(read_delay)

            # Collect all available output with a configurable timeout
            response_lines = []
            deadline = time.time() + timeout

            while time.time() < deadline:
                try:
                    line = self.output_queue.get(timeout=0.2)
                    if line is None:  # Error signal
                        self.connected = False
                        break
                    response_lines.append(line)
                    deadline = time.time() + 0.3  # Reset deadline if we're still receiving data
                except queue.Empty:
                    if response_lines:  # If we got some data, one more short wait
                        try:
                            line = self.output_queue.get(timeout=0.1)
                            if line:
                                response_lines.append(line)
                                continue
                        except queue.Empty:
                            pass
                    break

            return ''.join(response_lines)

        except Exception as e:
            self.connected = False
            raise RuntimeError(f"Error sending command '{cmd}': {e}")

    def close(self):
        """Close the connection"""
        if self.process and self.process.stdin:
            try:
                self.process.stdin.write('exit\n')
                self.process.stdin.flush()
            except:
                pass
        self.connected = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()


class OpenWattProcess:
    """Manages OpenWatt process lifecycle with --interactive mode"""

    def __init__(self, binary_path='bin/x86_64_debug/openwatt', startup_delay=3.0, use_debugger=False):
        # Make path absolute if relative
        if not Path(binary_path).is_absolute():
            # Assume relative to project root (parent of test/)
            script_dir = Path(__file__).parent
            project_root = script_dir.parent
            self.binary_path = project_root / binary_path
        else:
            self.binary_path = Path(binary_path)

        # Auto-detect .exe extension on Windows
        if not self.binary_path.exists() and platform.system() == 'Windows':
            exe_path = self.binary_path.with_suffix('.exe')
            if exe_path.exists():
                self.binary_path = exe_path

        # Store project root for setting working directory
        self.project_root = self.binary_path.parent.parent.parent  # bin/x86_64_debug/openwatt -> root

        self.startup_delay = startup_delay
        self.use_debugger = use_debugger
        self.process: Optional[subprocess.Popen] = None
        self.console: Optional[OpenWattConsole] = None
        self.output_lines: List[str] = []
        self.stderr_lines: List[str] = []
        self.crashed = False
        self.exit_code: Optional[int] = None
        self.crash_file = Path('test_crash_info.txt')
        self.output_file = Path('test_output.txt')
        self.log_file = Path('test_logs.txt')

    def start(self) -> bool:
        """Start OpenWatt process in interactive mode"""
        if not self.binary_path.exists():
            print(f"Error: Binary not found at {self.binary_path}")
            return False

        try:
            # Start process with --interactive flag and pipe stdin/stdout
            # Keep stderr separate so we can capture logs
            # Use line buffering (bufsize=1) for text mode
            # Run from project root so conf/startup.conf can be found
            self.process = subprocess.Popen(
                [str(self.binary_path), '--interactive'],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,  # Separate stderr for logs
                text=True,
                bufsize=1,
                encoding='utf-8',
                errors='replace',
                cwd=str(self.project_root)  # Run from project root
            )

            # Wait for startup
            time.sleep(self.startup_delay)

            # Check if process is still running
            exit_code = self.process.poll()
            if exit_code is not None:
                self.crashed = True
                self.exit_code = exit_code
                print(f"Error: Process terminated during startup (exit code: {exit_code})")
                self._capture_remaining_output()
                self._save_crash_info()
                return False

            # Create console wrapper
            self.console = OpenWattConsole(self.process)
            return True

        except Exception as e:
            print(f"Error starting process: {e}")
            return False

    def _capture_remaining_output(self):
        """Capture any remaining output from crashed process"""
        if self.process:
            # Capture stdout
            if self.process.stdout:
                try:
                    remaining = self.process.stdout.read()
                    if remaining:
                        self.output_lines.extend(remaining.splitlines())
                except:
                    pass

            # Capture stderr (assertions, error messages)
            if self.process.stderr:
                try:
                    remaining_err = self.process.stderr.read()
                    if remaining_err:
                        self.stderr_lines.extend(remaining_err.splitlines())
                except:
                    pass

    def _save_crash_info(self):
        """Save crash information to file for debugging"""
        try:
            crash_file = Path('crash_info.txt')
            with open(crash_file, 'w') as f:
                f.write(f"=== OpenWatt Crash Report ===\n")
                f.write(f"Binary: {self.binary_path}\n")
                f.write(f"Exit Code: {self.exit_code} (0x{self.exit_code:08X})\n")
                f.write(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                f.write(f"\n=== Exit Code Analysis ===\n")
                if self.exit_code == 2147483651:  # 0x80000003
                    f.write("STATUS_BREAKPOINT - Likely an assertion failure or __debugbreak()\n")
                elif self.exit_code == -1073741819:  # 0xC0000005
                    f.write("ACCESS_VIOLATION - Null pointer or invalid memory access\n")
                elif self.exit_code == -1073741571:  # 0xC00000FD
                    f.write("STACK_OVERFLOW - Stack overflow\n")
                else:
                    f.write(f"Unknown exit code\n")

                # Check for assertions in stderr
                assertions = [line for line in self.stderr_lines if 'assert' in line.lower() or 'assertion' in line.lower()]
                if assertions:
                    f.write(f"\n=== Assertion Failures ({len(assertions)}) ===\n")
                    for line in assertions:
                        f.write(f"{line}\n")

                f.write(f"\n=== STDERR ({len(self.stderr_lines)} lines) ===\n")
                if self.stderr_lines:
                    for line in self.stderr_lines[-50:]:  # Last 50 lines
                        f.write(f"{line}\n")
                else:
                    f.write("(No stderr captured)\n")

                f.write(f"\n=== STDOUT ({len(self.output_lines)} lines) ===\n")
                if self.output_lines:
                    for line in self.output_lines[-50:]:  # Last 50 lines
                        f.write(f"{line}\n")
                else:
                    f.write("(No stdout captured)\n")

            print(f"\n[CRASH DETECTED]")
            print(f"Exit code: {self.exit_code} (0x{self.exit_code:08X})")
            if assertions:
                print(f"Assertions found: {len(assertions)}")
                for line in assertions[:3]:  # Show first 3
                    print(f"  {line}")
            print(f"Full crash info saved to: {crash_file.absolute()}")
        except Exception as e:
            print(f"Failed to save crash info: {e}")

    def stop(self):
        """Stop OpenWatt process and cleanup temp files"""
        if self.console:
            self.console.close()
            self.console = None

        if self.process:
            # Capture any final stderr before killing
            if self.process.stderr:
                try:
                    remaining_stderr = self.process.stderr.read()
                    if remaining_stderr:
                        self.stderr_lines.extend(remaining_stderr.splitlines())
                except:
                    pass

            try:
                self.process.terminate()
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
            except:
                pass
            self.process = None

        # Cleanup temp files (unless crashed - keep crash info)
        if not self.crashed:
            for f in [self.crash_file, self.output_file, self.log_file]:
                try:
                    if f.exists():
                        f.unlink()
                except:
                    pass

    def is_running(self) -> bool:
        """Check if process is running"""
        if self.process is None:
            return False

        exit_code = self.process.poll()
        if exit_code is not None and not self.crashed:
            # Process just crashed
            self.crashed = True
            self.exit_code = exit_code
            self._capture_remaining_output()
            return False

        return exit_code is None

    def get_crash_info(self) -> Optional[Dict[str, Any]]:
        """Get crash information if process crashed"""
        if not self.crashed:
            return None

        return {
            'exit_code': self.exit_code,
            'output_lines': self.output_lines[-50:] if self.output_lines else [],
            'total_output_lines': len(self.output_lines)
        }

    def get_console(self) -> Optional[OpenWattConsole]:
        """Get console interface for sending commands"""
        return self.console

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()


class TestRunner:
    """Runs test cases against OpenWatt"""

    def __init__(self, auto_start=True):
        self.auto_start = auto_start
        self.process: Optional[OpenWattProcess] = None
        self.results: List[Dict[str, Any]] = []

    def run_test_suite(self, tests: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Run a suite of tests"""
        print(f"Running {len(tests)} tests...")
        print("=" * 60)

        if self.auto_start:
            self.process = OpenWattProcess()
            if not self.process.start():
                return {'success': False, 'error': 'Failed to start OpenWatt'}

        try:
            console = self.process.get_console()
            if not console:
                return {'success': False, 'error': 'Failed to get console'}

            for i, test in enumerate(tests, 1):
                # Check if process crashed
                if self.process and not self.process.is_running():
                    crash_info = self.process.get_crash_info()
                    error_msg = f"OpenWatt crashed (exit code: {crash_info['exit_code']})"
                    print(f"\n[CRASH] {error_msg}")
                    if crash_info['output_lines']:
                        print("Last output lines:")
                        for line in crash_info['output_lines'][-10:]:
                            print(f"  {line}")
                    return {
                        'success': False,
                        'error': 'Process crashed during testing',
                        'crash_info': crash_info,
                        'results': self.results
                    }

                print(f"\n[{i}/{len(tests)}] {test.get('name', 'Unnamed test')}")
                result = self._run_test(console, test)
                self.results.append(result)

                if result['success']:
                    print(f"  [PASS]")
                else:
                    print(f"  [FAIL]: {result.get('error', 'Unknown error')}")

                # Stop on first failure if requested
                if not result['success'] and test.get('stop_on_fail', False):
                    break

        finally:
            if self.auto_start and self.process:
                self.process.stop()

        # Summary
        passed = sum(1 for r in self.results if r['success'])
        failed = len(self.results) - passed

        print("\n" + "=" * 60)
        print(f"Results: {passed} passed, {failed} failed")

        return {
            'success': failed == 0,
            'passed': passed,
            'failed': failed,
            'results': self.results
        }

    def _run_test(self, console: OpenWattConsole, test: Dict[str, Any]) -> Dict[str, Any]:
        """Run a single test"""
        cmd = test.get('command')
        if not cmd:
            return {'success': False, 'error': 'No command specified'}

        try:
            response = console.send_command(cmd, read_delay=test.get('delay', 0.5))

            # Check assertions
            assertions = test.get('assertions', [])
            for assertion in assertions:
                if not self._check_assertion(response, assertion):
                    return {
                        'success': False,
                        'error': f"Assertion failed: {assertion}",
                        'response': response[:500]
                    }

            return {
                'success': True,
                'command': cmd,
                'response_length': len(response)
            }

        except Exception as e:
            return {
                'success': False,
                'error': str(e),
                'command': cmd
            }

    def _check_assertion(self, response: str, assertion: Dict[str, Any]) -> bool:
        """Check if assertion passes"""
        atype = assertion.get('type')

        if atype == 'contains':
            return assertion['value'] in response
        elif atype == 'not_contains':
            return assertion['value'] not in response
        elif atype == 'regex':
            return bool(re.search(assertion['pattern'], response))
        elif atype == 'min_length':
            return len(response) >= assertion['value']
        elif atype == 'no_error':
            return 'Error:' not in response

        return False


def quick_test(commands: List[str], output_file: Optional[str] = None, log_file: Optional[str] = None) -> bool:
    """Quick test - run commands and optionally save output and logs"""
    print("Starting OpenWatt...")
    with OpenWattProcess() as proc:
        if not proc.is_running():
            print("Failed to start OpenWatt")
            return False

        console = proc.get_console()
        if not console:
            print("Failed to get console")
            return False

        results = {}

        for cmd in commands:
            print(f"\nExecuting: {cmd}")
            try:
                response = console.send_command(cmd)
                results[cmd] = response

                # Print preview
                preview = response[:200].replace('\n', ' ').strip()
                print(f"  Response: {preview}...")

            except Exception as e:
                print(f"  Error: {e}")
                results[cmd] = f"ERROR: {e}"

        # Save output if requested
        if output_file:
            with open(output_file, 'w', encoding='utf-8') as f:
                for cmd, response in results.items():
                    f.write(f"\n{'='*60}\n")
                    f.write(f"Command: {cmd}\n")
                    f.write(f"{'='*60}\n")
                    f.write(response)
                    f.write("\n")
            print(f"\nOutput saved to {output_file}")

        # Capture and save logs from stderr if requested
        if log_file and proc.process and proc.process.stderr:
            try:
                # Read any remaining stderr output
                stderr_data = proc.process.stderr.read()
                if stderr_data:
                    with open(log_file, 'w', encoding='utf-8') as f:
                        f.write(stderr_data)
                    print(f"Logs saved to {log_file}")
            except:
                pass

        return True


def main():
    """Example usage"""
    import argparse

    parser = argparse.ArgumentParser(description='OpenWatt Test Harness')
    parser.add_argument('--quick', action='store_true', help='Quick test mode')
    parser.add_argument('--commands', nargs='+', help='Commands to run in quick mode')
    parser.add_argument('--output', help='Output file for results')
    parser.add_argument('--suite', help='JSON file with test suite')

    args = parser.parse_args()

    if args.quick:
        commands = args.commands or ['/device/print', '/stream/tcp-client/print']
        quick_test(commands, args.output)

    elif args.suite:
        with open(args.suite) as f:
            tests = json.load(f)
        runner = TestRunner()
        result = runner.run_test_suite(tests)
        sys.exit(0 if result['success'] else 1)

    else:
        parser.print_help()


if __name__ == '__main__':
    main()