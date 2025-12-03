#!/usr/bin/env python3
"""
Quick test runner for OpenWatt
Use this for rapid sanity checks during development
"""

import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from test_harness import quick_test


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='OpenWatt Quick Test')
    parser.add_argument('commands', nargs='*', help='Commands to run (default: /system/sysinfo)')

    args = parser.parse_args()

    # Default to sysinfo if no commands provided
    commands = args.commands if args.commands else ['/system/sysinfo']

    success = quick_test(commands, output_file='test_output.txt', log_file='test_logs.txt')
    sys.exit(0 if success else 1)
