"""Authored complete-date CLI parity with pinned Core 1.10.5/dateutil 2.9.0.

Deliberately excludes dateutil's current-date defaults and general prose grammar.
"""
import json
import subprocess

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_state import project, invoke, core_ids, selected_ids


def core(root, target):
    return subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root),
                           '--profiles-dir', str(root), '--target-path', str(target)],
                          text=True, capture_output=True)


def write(root, models):
    (root / 'models' / 'schema.yml').write_text(json.dumps({'version': 2, 'models': models}))


def pair(root, native, upstream):
    actual = invoke(root, 'parse', '--target-path', native)
    reference = core(root, upstream)
    assert actual.returncode == reference.returncode == 0, actual.stderr + reference.stdout + reference.stderr
    def dates(target):
        return {key: node['deprecation_date'] for key, node in json.loads((target / 'manifest.json').read_text())['nodes'].items()}
    assert dates(native) == dates(upstream)
    return dates(native)


@pytest.mark.parametrize('tz', ['UTC', 'America/New_York'])
@pytest.mark.parametrize('authored,canonical', [
    ('January 2, 2099', '2099-01-02T00:00:00'),
    ('2 jAn 2099', '2099-01-02T00:00:00'),
    ('2099-January-2', '2099-01-02T00:00:00'),
    ('Jan. 2, 2099', '2099-01-02T00:00:00'),
    ('2 Sept. 2099', '2099-09-02T00:00:00'),
    ('01/02/2099', '2099-01-02T00:00:00'),
    ('23/01/2099', '2099-01-23T00:00:00'),
    ('2099/01/02', '2099-01-02T00:00:00'),
    ('01.02.2099', '2099-01-02T00:00:00'),
    ('2099.01.02', '2099-01-02T00:00:00'),
    ('January 2 2099 03:04:05.123456+05:30', '2099-01-02T03:04:05.123456+05:30'),
    ('2-Jan-2099 03:04:05.123456789-0330', '2099-01-02T03:04:05.123456-03:30'),
    ('January 2 2099 03:04+05:99', '2099-01-02T03:04:00+06:39'),
])
def test_authored_complete_dates_core_oracle(tmp_path, monkeypatch, tz, authored, canonical):
    monkeypatch.setenv('TZ', tz)
    root = project(tmp_path)
    native, upstream = tmp_path / 'native', tmp_path / 'core'
    write(root, [{'name': 'a', 'deprecation_date': authored}])
    actual = pair(root, native, upstream)['model.usability_state.a']
    if canonical[-6:-5] not in ['+', '-']:
        suffix = '+00:00' if tz == 'UTC' else ('-04:00' if '09-02' in canonical else '-05:00')
        canonical += suffix
    assert actual == canonical


@pytest.mark.parametrize('authored', ['February 29 2099', 'January 2 2099 25:00',
                                       'January 2 2099 03:04+05:30:01',
                                       'January 2 2099 03:04+05:30.5', 1, False, {}])
def test_invalid_authored_dates_core_oracle(tmp_path, authored):
    root = project(tmp_path)
    write(root, [{'name': 'a', 'deprecation_date': authored}])
    assert invoke(root, 'parse').returncode == core(root, tmp_path / 'core').returncode == 2


def test_textual_date_warm_cache_and_property_change_core_oracle(tmp_path):
    root = project(tmp_path)
    native, upstream = tmp_path / 'native', tmp_path / 'core'
    write(root, [{'name': 'a', 'deprecation_date': 'January 2 2099 03:04:05Z'}])
    expected = pair(root, native, upstream)
    assert pair(root, native, upstream) == expected
    write(root, [{'name': 'a', 'deprecation_date': 'February 3 2099 04:05:06Z'}])
    assert pair(root, native, upstream)['model.usability_state.a'] == '2099-02-03T04:05:06+00:00'


@pytest.mark.parametrize('parent', ['January 2 2099', None])
def test_version_date_scope_core_oracle(tmp_path, parent):
    root = project(tmp_path)
    (root / 'models' / 'a.sql').rename(root / 'models' / 'a_v1.sql')
    (root / 'models' / 'a_v2.sql').write_text('select 2 as id')
    write(root, [{'name': 'a', 'latest_version': 2, 'deprecation_date': parent,
                  'versions': [{'v': 1, 'deprecation_date': '2 February 2099'}, {'v': 2}]}])
    dates = pair(root, tmp_path / 'native', tmp_path / 'core')
    assert dates['model.usability_state.a.v1'].startswith('2099-02-02T00:00:00')
    assert dates['model.usability_state.a.v2'] is None


def test_invalid_parent_date_validated_before_versions_core_oracle(tmp_path):
    root = project(tmp_path)
    (root / 'models' / 'a.sql').rename(root / 'models' / 'a_v1.sql')
    write(root, [{'name': 'a', 'deprecation_date': 'February 29 2099',
                  'versions': [{'v': 1, 'deprecation_date': 'January 2 2099'}]}])
    assert invoke(root, 'parse').returncode == core(root, tmp_path / 'core').returncode == 2


def test_textual_iso_and_equivalent_offset_state_core_oracle(tmp_path):
    root = project(tmp_path)
    write(root, [{'name': 'a', 'deprecation_date': 'January 2 2099 03:04:05.123456+05:30'}])
    state = tmp_path / 'state'
    result = core(root, state)
    assert result.returncode == 0, result.stdout + result.stderr
    for authored, modified in [('2099-01-02T03:04:05.123456+05:30', False),
                               ('January 1 2099 21:34:05.123456Z', False),
                               ('January 1 2099 21:34:05.123457Z', True)]:
        write(root, [{'name': 'a', 'deprecation_date': authored}])
        args = ('--state', state, '--select', 'state:modified', '--indirect-selection', 'empty')
        expected = core_ids(root, tmp_path / 'current', *args)
        assert ('model.usability_state.a' in expected) is modified
        assert selected_ids(root, *args) == expected


@pytest.mark.parametrize('authored,expected', [
    ('0001-01-02T03:04:05Z', '0001-01-02T03:04:05+00:00'),
    ('09990102T030405Z', '0999-01-02T03:04:05+00:00'),
])
def test_low_calendar_iso_years_core_oracle(tmp_path, authored, expected):
    root = project(tmp_path)
    write(root, [{'name': 'a', 'deprecation_date': authored}])
    assert pair(root, tmp_path / 'native', tmp_path / 'core')['model.usability_state.a'] == expected
