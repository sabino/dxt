"""Developer-only scheduling and complete-evidence checks for Core CI shards."""
from __future__ import annotations

from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import xml.etree.ElementTree as ET

from check_pytest_report import validate_report


FORMAT_VERSION = 1
NODE_PROPERTY = 'dxt_nodeid'


def source_identity(root: Path) -> dict:
    """Bind reports to source contents, including unstaged developer edits."""
    result = subprocess.run(['git', 'ls-files', '-z', '--cached'],
                            cwd=root, capture_output=True, check=False)
    if result.returncode == 0:
        additional = subprocess.run(['git', 'ls-files', '-z', '--others', '--exclude-standard',
                                     '--', 'src', 'tests', 'scripts', '.github'],
                                    cwd=root, capture_output=True, check=True)
        paths = sorted(set((result.stdout + additional.stdout).split(b'\0')) - {b''})
        commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root,
                                capture_output=True, text=True, check=True).stdout.strip()
    else:
        # Standalone pytest fixtures exercise the same plugin without a Git repo.
        paths = [str(path.relative_to(root)).encode() for path in sorted(root.rglob('*.py'))]
        commit = None
    digest = hashlib.sha256()
    for relative in paths:
        path = root / relative.decode()
        digest.update(relative + b'\0')
        digest.update(path.read_bytes())
        digest.update(b'\0')
    return {'commit': commit, 'digest': digest.hexdigest()}


def runtime_identity() -> dict:
    return {'system': platform.system(), 'machine': platform.machine(),
            'python': f'{sys.version_info.major}.{sys.version_info.minor}'}


def unique_nodes(nodes: list[str], label: str) -> set[str]:
    if not nodes or any(not isinstance(node, str) or '::' not in node for node in nodes):
        raise ValueError(f'{label} must contain test node IDs')
    if len(set(nodes)) != len(nodes):
        raise ValueError(f'{label} contains duplicate cases')
    return set(nodes)


def make_plan(nodes: list[str], shard_count: int, weights: dict[str, float], source: dict) -> dict:
    unique_nodes(nodes, 'Full collection')
    if shard_count <= 0:
        raise ValueError('Shard count must be positive')
    groups = Counter(node.split('::', 1)[0] for node in nodes)
    if len(groups) < shard_count:
        raise ValueError('Shard count exceeds the number of test modules')
    costs = {}
    for module, count in groups.items():
        cost = float(weights.get(module, count * 2.2))
        if not math.isfinite(cost) or cost <= 0:
            raise ValueError(f'Invalid scheduling weight for {module}')
        costs[module] = cost
    loads = [0.0] * shard_count
    modules = {}
    for module in sorted(groups, key=lambda name: (-costs[name], name)):
        shard = min(range(shard_count), key=lambda index: (loads[index], index))
        modules[module] = {'shard': shard, 'estimated_seconds': costs[module]}
        loads[shard] += costs[module]
    return {'format_version': FORMAT_VERSION, 'source': source,
            'shard_count': shard_count, 'collected': nodes, 'modules': modules}


def validate_plan(plan: dict) -> None:
    if plan['format_version'] != FORMAT_VERSION:
        raise ValueError('Unsupported compatibility plan format')
    nodes = unique_nodes(plan['collected'], 'Full collection')
    count = plan['shard_count']
    if type(count) is not int or count <= 0:
        raise ValueError('Invalid shard count')
    modules = {node.split('::', 1)[0] for node in nodes}
    if modules != set(plan['modules']):
        raise ValueError('Module assignments do not match the full collection')
    assignments = [value['shard'] for value in plan['modules'].values()]
    if any(type(index) is not int or not 0 <= index < count for index in assignments):
        raise ValueError('Invalid module shard assignment')
    if set(assignments) != set(range(count)):
        raise ValueError('Plan contains an empty shard')
    if not isinstance(plan['source']['digest'], str) or len(plan['source']['digest']) != 64:
        raise ValueError('Missing source fingerprint')


def assigned_nodes(plan: dict, index: int) -> list[str]:
    validate_plan(plan)
    if not 0 <= index < plan['shard_count']:
        raise ValueError('Shard index is outside the plan')
    return [node for node in plan['collected']
            if plan['modules'][node.split('::', 1)[0]]['shard'] == index]


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + '\n')


def validate_shards(plan_path: Path, directory: Path, source: dict | None = None,
                    runtime: dict | None = None) -> int:
    plan = json.loads(plan_path.read_text())
    validate_plan(plan)
    if source is not None and plan['source'] != source:
        raise ValueError('Plan was collected from different source contents')
    count = plan['shard_count']
    expected_paths = {directory / f'shard-{index}.json' for index in range(count)}
    if set(directory.glob('shard-*.json')) != expected_paths:
        raise ValueError('Missing or unexpected shard manifests')
    expected_xml = {directory / f'shard-{index}.xml' for index in range(count)}
    if set(directory.glob('shard-*.xml')) != expected_xml:
        raise ValueError('Missing or unexpected shard JUnit reports')
    executed = []
    first_runtime = None
    for index in range(count):
        result = json.loads((directory / f'shard-{index}.json').read_text())
        if (result['format_version'] != FORMAT_VERSION or result['shard_index'] != index
                or result['source'] != plan['source'] or result['shard_count'] != count):
            raise ValueError(f'Shard {index} has mismatched identity')
        if first_runtime is None:
            first_runtime = result['runtime']
        if result['runtime'] != first_runtime or (runtime is not None and result['runtime'] != runtime):
            raise ValueError(f'Shard {index} ran on a different platform or Python runtime')
        if result['collected'] != plan['collected']:
            raise ValueError(f'Shard {index} did not collect the complete suite')
        expected = assigned_nodes(plan, index)
        if result['assigned'] != expected:
            raise ValueError(f'Shard {index} has missing, reordered or duplicate assignments')
        if result['exit_status'] != 0:
            raise ValueError(f'Shard {index} did not exit successfully')
        unique_nodes(result['passed'], f'Shard {index} executed cases')
        if set(result['passed']) != set(expected):
            raise ValueError(f'Shard {index} did not pass every assigned case')
        report = directory / f'shard-{index}.xml'
        validate_report(report, len(expected))
        junit_nodes = []
        for case in ET.parse(report).getroot().iter('testcase'):
            properties = [prop.get('value') for prop in case.findall('properties/property')
                          if prop.get('name') == NODE_PROPERTY]
            if len(properties) != 1:
                raise ValueError(f'Shard {index} has a JUnit case without exactly one node ID')
            junit_nodes.append(properties[0])
        unique_nodes(junit_nodes, f'Shard {index} JUnit cases')
        if set(junit_nodes) != set(expected):
            raise ValueError(f'Shard {index} JUnit identities do not match its assignment')
        executed.extend(junit_nodes)
    if len(executed) != len(set(executed)) or set(executed) != set(plan['collected']):
        raise ValueError('Executed shards do not form the disjoint complete collection')
    return len(executed)
