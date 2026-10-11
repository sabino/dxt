"""Reject incomplete or skipped developer compatibility evidence."""
from __future__ import annotations

import argparse
from pathlib import Path
import xml.etree.ElementTree as ET


def validate_report(path: Path, expected_tests: int | None = None) -> int:
    root = ET.parse(path).getroot()
    if root.tag not in {'testsuite', 'testsuites'}:
        raise ValueError('Expected a pytest JUnit testsuite or testsuites report')
    suites = [root] if root.tag == 'testsuite' else list(root.iter('testsuite'))
    cases = list(root.iter('testcase'))
    if not suites or not cases:
        raise ValueError('Compatibility report contains no executed tests')
    # pytest emits leaf suites; nested aggregate counts must not double-count.
    if any(suite.find('testsuite') is not None for suite in suites):
        raise ValueError('Expected pytest leaf test suites')
    declared = 0
    for suite in suites:
        counts = {name: int(suite.attrib[name]) for name in ('tests', 'failures', 'errors', 'skipped')}
        if any(value < 0 for value in counts.values()):
            raise ValueError('Compatibility report has negative test counts')
        if any(counts[name] for name in ('failures', 'errors', 'skipped')):
            raise ValueError('Compatibility evidence requires zero failures, errors and skipped/xfail tests')
        declared += counts['tests']
    if any(case.find(name) is not None for case in cases for name in ('failure', 'error', 'skipped')):
        raise ValueError('Compatibility evidence contains a failure, error or skipped/xfail case')
    if declared != len(cases):
        raise ValueError('Compatibility report counts do not match its test cases')
    if expected_tests is not None and len(cases) != expected_tests:
        raise ValueError(f'Expected {expected_tests} tests, received {len(cases)}')
    return len(cases)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--expected-tests', type=int)
    args = parser.parse_args()
    if args.expected_tests is not None and args.expected_tests <= 0:
        parser.error('--expected-tests must be positive')
    try:
        count = validate_report(args.report, args.expected_tests)
    except (OSError, ET.ParseError, ValueError, KeyError) as error:
        parser.exit(1, f'Compatibility report failed: {error}\n')
    print(f'Compatibility report passed: {count} tests, zero failures, errors or skipped/xfail cases')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
