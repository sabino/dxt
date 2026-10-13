"""Distribution must preserve all cases and fail closed on incomplete evidence."""
from concurrent.futures import ThreadPoolExecutor
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

import pytest

from compatibility_shards import (
    FORMAT_VERSION, NODE_PROPERTY, assigned_nodes, make_plan, runtime_identity,
    source_identity, validate_shards, write_json,
)


SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
SOURCE = {'commit': 'fixture', 'digest': 'a' * 64}


def passing_evidence(tmp_path):
    nodes = [f'tests/test_{module}.py::test_value[{case}]'
             for module in range(4) for case in range(3)]
    plan = make_plan(nodes, 2, {}, SOURCE)
    plan_path = tmp_path / 'plan.json'
    reports = tmp_path / 'reports'
    write_json(plan_path, plan)
    for index in range(2):
        assigned = assigned_nodes(plan, index)
        write_json(reports / f'shard-{index}.json', {
            'format_version': FORMAT_VERSION, 'source': SOURCE, 'runtime': runtime_identity(),
            'shard_index': index, 'shard_count': 2, 'collected': nodes,
            'assigned': assigned, 'passed': assigned, 'exit_status': 0,
        })
        suite = ET.Element('testsuite', tests=str(len(assigned)), failures='0', errors='0', skipped='0')
        for node in assigned:
            case = ET.SubElement(suite, 'testcase', name=node.split('::')[-1])
            properties = ET.SubElement(case, 'properties')
            ET.SubElement(properties, 'property', name=NODE_PROPERTY, value=node)
        ET.ElementTree(suite).write(reports / f'shard-{index}.xml')
    return plan_path, reports


def test_balancing_keeps_complete_modules_and_original_case_order():
    nodes = ['test_heavy.py::test_a[0]', 'test_heavy.py::test_a[1]',
             'test_medium.py::test_b', 'test_small.py::test_c']
    plan = make_plan(nodes, 2, {'test_heavy.py': 10, 'test_medium.py': 6, 'test_small.py': 4}, SOURCE)
    assert assigned_nodes(plan, 0) == nodes[:2]
    assert assigned_nodes(plan, 1) == nodes[2:]
    # Discovery order does not change module assignments.
    assert make_plan(list(reversed(nodes)), 2, {'test_heavy.py': 10, 'test_medium.py': 6,
                                              'test_small.py': 4}, SOURCE)['modules'] == plan['modules']


def test_new_modules_are_required_without_historical_timings():
    plan = make_plan(['new.py::test_a', 'known.py::test_b'], 2, {'known.py': 5}, SOURCE)
    assert set(assigned_nodes(plan, 0) + assigned_nodes(plan, 1)) == set(plan['collected'])


@pytest.mark.parametrize('nodes,count,weights', [
    ([], 1, {}), (['a.py::test_a'] * 2, 1, {}),
    (['a.py::test_a'], 0, {}), (['a.py::test_a'], 2, {}),
    (['a.py::test_a'], 1, {'a.py': float('nan')}),
    (['a.py::test_a'], 1, {'a.py': -1}),
])
def test_invalid_collection_or_distribution_is_rejected(nodes, count, weights):
    with pytest.raises(ValueError):
        make_plan(nodes, count, weights, SOURCE)


def test_complete_evidence_passes_and_wrong_source_fails(tmp_path):
    plan, reports = passing_evidence(tmp_path)
    assert validate_shards(plan, reports, SOURCE, runtime_identity()) == 12
    with pytest.raises(ValueError, match='source'):
        validate_shards(plan, reports, dict(SOURCE, digest='b' * 64))


@pytest.mark.parametrize('damage', [
    'missing_manifest', 'extra_manifest', 'missing_xml', 'extra_xml',
    'source', 'runtime', 'exit_status', 'collection', 'duplicate_collection',
    'assignment', 'duplicate_assignment', 'missing_pass', 'duplicate_pass',
    'same_count_wrong_pass', 'skip', 'failure', 'xfail', 'missing_node_property',
    'duplicate_node_property', 'same_count_wrong_junit', 'duplicate_junit',
])
def test_aggregate_rejects_incomplete_or_misleading_evidence(tmp_path, damage):
    plan, reports = passing_evidence(tmp_path)
    manifest = reports / 'shard-0.json'
    document = json.loads(manifest.read_text())
    xml_path = reports / 'shard-0.xml'
    tree = ET.parse(xml_path)
    case = tree.getroot().find('testcase')
    prop = case.find('properties/property')
    if damage == 'missing_manifest':
        manifest.unlink()
    elif damage == 'extra_manifest':
        (reports / 'shard-9.json').write_text(manifest.read_text())
    elif damage == 'missing_xml':
        xml_path.unlink()
    elif damage == 'extra_xml':
        (reports / 'shard-9.xml').write_bytes(xml_path.read_bytes())
    elif damage in {'source', 'runtime'}:
        document[damage] = {'wrong': True}
    elif damage == 'exit_status':
        document['exit_status'] = 1
    elif damage in {'collection', 'duplicate_collection'}:
        document['collected'] = document['collected'][:-1] + (
            [document['collected'][0]] if damage == 'duplicate_collection' else [])
    elif damage in {'assignment', 'duplicate_assignment'}:
        document['assigned'] = document['assigned'][:-1] + (
            [document['assigned'][0]] if damage == 'duplicate_assignment' else [])
    elif damage == 'missing_pass':
        document['passed'].pop()
    elif damage == 'duplicate_pass':
        document['passed'].append(document['passed'][0])
    elif damage == 'same_count_wrong_pass':
        document['passed'][0] = 'unassigned.py::test_other'
    elif damage in {'skip', 'failure', 'xfail'}:
        ET.SubElement(case, 'failure' if damage == 'failure' else 'skipped', type=damage)
    elif damage == 'missing_node_property':
        case.find('properties').remove(prop)
    elif damage == 'duplicate_node_property':
        case.find('properties').append(copy.deepcopy(prop))
    elif damage == 'same_count_wrong_junit':
        prop.set('value', 'unassigned.py::test_other')
    elif damage == 'duplicate_junit':
        prop.set('value', tree.getroot().findall('testcase')[1].find('properties/property').get('value'))
    if damage != 'missing_manifest':
        write_json(manifest, document)
    if damage != 'missing_xml':
        tree.write(xml_path)
    with pytest.raises((ValueError, KeyError)):
        validate_shards(plan, reports, SOURCE, runtime_identity())


def invoke_pytest(root, *arguments):
    environment = dict(os.environ, PYTHONPATH=str(SCRIPTS), PYTEST_DISABLE_PLUGIN_AUTOLOAD='1')
    # Host pytest selection must not leak into the separate fixture processes.
    environment.pop('PYTEST_ADDOPTS', None)
    return subprocess.run([sys.executable, '-m', 'pytest', '-q', '-p', 'pytest_shard', *arguments],
                          cwd=root, env=environment, capture_output=True, text=True, timeout=90)


@pytest.mark.parametrize('workers', [1, 2, 4])
def test_real_pytest_processes_preserve_collection_fixtures_and_junit(tmp_path, workers):
    for module in range(4):
        (tmp_path / f'test_{module}.py').write_text(
            "import pytest\n"
            "@pytest.fixture(scope='module', autouse=True)\n"
            "def module_fixture(tmp_path_factory):\n"
            "    marker=tmp_path_factory.mktemp('module')/'fixture'\n"
            "    marker.write_text('ready')\n"
            "    yield marker\n"
            "    assert marker.read_text()=='ready'\n"
            "@pytest.mark.parametrize('value',range(7))\n"
            "def test_value(value,module_fixture):\n"
            "    assert module_fixture.read_text()=='ready'\n"
            "    assert value*value>=0\n"
        )
    plan = tmp_path / 'plan.json'
    result = invoke_pytest(tmp_path, '--collect-only', f'--dxt-shard-count={workers}',
                           f'--dxt-shard-output={plan}')
    assert result.returncode == 0, result.stdout + result.stderr
    reports = tmp_path / 'reports'

    def run(index):
        return invoke_pytest(tmp_path, f'--dxt-shard-plan={plan}', f'--dxt-shard-index={index}',
                             f'--dxt-shard-output={reports / f"shard-{index}.json"}',
                             f'--junitxml={reports / f"shard-{index}.xml"}')

    # Threads only launch isolated pytest subprocesses; test bodies never share a process.
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for result in pool.map(run, range(workers)):
            assert result.returncode == 0, result.stdout + result.stderr
    assert validate_shards(plan, reports, source_identity(tmp_path), runtime_identity()) == 28


@pytest.mark.parametrize('outcome', ['skip', 'xfail', 'failure', 'teardown_error'])
def test_real_pytest_incomplete_results_fail_acceptance(tmp_path, outcome):
    bodies = {
        'skip': "import pytest\ndef test_case():pytest.skip('optional')\n",
        'xfail': "import pytest\n@pytest.mark.xfail(reason='expected')\ndef test_case():assert False\n",
        'failure': "def test_case():assert False\n",
        'teardown_error': "import pytest\n@pytest.fixture\ndef bad():\n yield\n assert False\ndef test_case(bad):pass\n",
    }
    (tmp_path / 'test_case.py').write_text(bodies[outcome])
    plan = tmp_path / 'plan.json'
    reports = tmp_path / 'reports'
    assert invoke_pytest(tmp_path, '--collect-only', '--dxt-shard-count=1',
                         f'--dxt-shard-output={plan}').returncode == 0
    invoke_pytest(tmp_path, f'--dxt-shard-plan={plan}', '--dxt-shard-index=0',
                  f'--dxt-shard-output={reports / "shard-0.json"}',
                  f'--junitxml={reports / "shard-0.xml"}')
    with pytest.raises(ValueError):
        validate_shards(plan, reports)


def test_source_change_after_collection_is_rejected(tmp_path):
    path = tmp_path / 'test_case.py'
    path.write_text('def test_case():pass\n')
    plan = tmp_path / 'plan.json'
    assert invoke_pytest(tmp_path, '--collect-only', '--dxt-shard-count=1',
                         f'--dxt-shard-output={plan}').returncode == 0
    path.write_text('def test_case():assert False\n')
    result = invoke_pytest(tmp_path, f'--dxt-shard-plan={plan}', '--dxt-shard-index=0',
                           f'--dxt-shard-output={tmp_path / "result.json"}')
    assert result.returncode != 0
    assert 'Source contents changed' in result.stderr
