#!/usr/bin/env python3
"""
Example usage patterns for OpenWatt test harness

Shows different testing workflows for development
"""

import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from test_session import TestSession


def example_basic_session():
    """Basic test session - start once, test multiple commands"""
    print("=" * 60)
    print("Example: Basic Test Session")
    print("=" * 60)

    with TestSession() as session:
        # Test device listing
        session.cmd('/device/print')
        session.expect_no_error()
        session.expect_contains('energy-meter')

        # Test stream listing
        session.cmd('/stream/tcp-client/print')
        session.expect_no_error()

        # Save output for analysis
        session.save_response('device_output.txt')


def example_iterative_development():
    """Simulating iterative development workflow"""
    print("=" * 60)
    print("Example: Iterative Development Workflow")
    print("=" * 60)

    session = TestSession()
    session.start()

    try:
        # Initial test
        print("\n[Phase 1] Test initial implementation")
        session.cmd('/device/print', delay=0.8)
        has_data = session.expect_min_length(500)

        if not has_data:
            print("  No data yet - devices not ready?")

        # Developer makes code changes here, rebuilds...
        print("\n[Phase 2] After code changes...")
        print("  (In real workflow: you'd rebuild and restart here)")

        # Test again
        session.cmd('/device/print', delay=0.8)
        session.expect_contains('voltage', 'voltage data present')
        session.expect_contains('current', 'current data present')

        # Verify specific device
        print("\n[Phase 3] Verify specific device behavior")
        session.cmd('/device/print', delay=0.8)
        if session.expect_contains('goodwe_ems'):
            print("  GoodWe EMS device found")
            # Could parse response for specific values here
            if 'battery' in session.last_response.lower():
                print("  Battery data available")

    finally:
        session.stop()


def example_regression_testing():
    """Quick regression test suite"""
    print("=" * 60)
    print("Example: Regression Test Suite")
    print("=" * 60)

    tests_passed = 0
    tests_failed = 0

    with TestSession() as session:
        # Test 1: System responds
        session.cmd('/system')
        if session.expect_no_error():
            tests_passed += 1
        else:
            tests_failed += 1

        # Test 2: Devices exist
        session.cmd('/device/print', delay=0.8)
        if session.expect_min_length(100) and session.expect_no_error():
            tests_passed += 1
        else:
            tests_failed += 1

        # Test 3: Device data structure
        session.cmd('/device/print', delay=0.8)
        checks = [
            session.expect_contains('info:'),
            session.expect_contains('realtime:'),
            session.expect_contains('voltage'),
        ]
        if all(checks):
            tests_passed += 1
        else:
            tests_failed += 1

        # Test 4: Streams configured
        session.cmd('/stream/tcp-client/print')
        if session.expect_no_error():
            tests_passed += 1
        else:
            tests_failed += 1

    print(f"\n{'='*60}")
    print(f"Results: {tests_passed} passed, {tests_failed} failed")
    print(f"{'='*60}")

    return tests_failed == 0


def example_quiet_mode():
    """Quiet mode for scripting"""
    print("=" * 60)
    print("Example: Quiet Mode (minimal output)")
    print("=" * 60)

    with TestSession() as session:
        session.quiet()  # Disable verbose output

        # Just get the data
        response = session.cmd('/device/print', delay=0.8)

        # Manual validation
        if 'Error:' in response:
            print("FAIL: Command returned error")
        elif len(response) < 100:
            print("FAIL: Response too short")
        else:
            print(f"PASS: Got {len(response)} chars of device data")

            # Count devices
            device_count = response.count('info:')
            print(f"      Found {device_count} devices")


def example_crash_detection():
    """Test crash detection"""
    print("=" * 60)
    print("Example: Crash Detection")
    print("=" * 60)

    session = TestSession()
    session.start()

    try:
        # Send some commands
        session.cmd('/device/print')

        # This would crash OpenWatt (example - don't actually run)
        # session.cmd('/trigger/crash')

        # Check if still running
        if not session.is_running():
            print("OpenWatt crashed!")
        else:
            print("OpenWatt still running")

            # Do more tests...
            session.cmd('/stream/tcp-client/print')

    finally:
        session.stop()


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='OpenWatt Test Examples')
    parser.add_argument('example', nargs='?', default='basic',
                       choices=['basic', 'iterative', 'regression', 'quiet', 'crash'],
                       help='Which example to run')

    args = parser.parse_args()

    examples = {
        'basic': example_basic_session,
        'iterative': example_iterative_development,
        'regression': example_regression_testing,
        'quiet': example_quiet_mode,
        'crash': example_crash_detection,
    }

    success = examples[args.example]()
    sys.exit(0 if success else 1)