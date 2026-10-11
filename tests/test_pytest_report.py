"""Final acceptance must reject a successful pytest invocation with skips."""
from pathlib import Path
import subprocess
import sys

import pytest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check_pytest_report.py'


@pytest.mark.parametrize('body, expected, success', [
    ('<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase name="a"/><testcase name="b"/></testsuite>', 2, True),
    ('<testsuite tests="1" failures="0" errors="0" skipped="1"><testcase name="optional"><skipped type="pytest.skip"/></testcase></testsuite>', 1, False),
    ('<testsuite tests="1" failures="0" errors="0" skipped="1"><testcase name="expected"><skipped type="pytest.xfail"/></testcase></testsuite>', 1, False),
    ('<testsuite tests="1" failures="0" errors="0" skipped="0"><testcase name="hidden"><skipped/></testcase></testsuite>', 1, False),
    ('<testsuite tests="0" failures="0" errors="0" skipped="0"/>', 1, False),
    ('<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase name="missing"/></testsuite>', 2, False),
    ('<testsuite tests="1" failures="0" errors="0" skipped="0"><testcase name="subset"/></testsuite>', 2, False),
    ('<testsuite tests="1" failures="1" errors="0" skipped="0"><testcase name="failed"><failure/></testcase></testsuite>', 1, False),
    ('<testsuite tests="1" failures="0" errors="1" skipped="0"><testcase name="broken"><error/></testcase></testsuite>', 1, False),
])
def test_acceptance_report_requires_every_expected_case_to_pass(tmp_path, body, expected, success):
    report = tmp_path / 'junit.xml'
    report.write_text('<testsuites>' + body + '</testsuites>')
    result = subprocess.run([sys.executable, SCRIPT, report, '--expected-tests', str(expected)], text=True, capture_output=True)
    assert (result.returncode == 0) is success, result.stdout + result.stderr
    assert ('zero failures' in result.stdout) is success


def test_acceptance_report_fails_closed_for_a_missing_report(tmp_path):
    result = subprocess.run([sys.executable, SCRIPT, tmp_path / 'missing.xml'], text=True, capture_output=True)
    assert result.returncode == 1
    assert 'Compatibility report failed' in result.stderr
