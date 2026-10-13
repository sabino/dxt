"""Opt-in pytest plugin: whole-module shards with full collection evidence."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from compatibility_shards import (
    FORMAT_VERSION, NODE_PROPERTY, assigned_nodes, make_plan, runtime_identity, source_identity,
    validate_plan, write_json,
)


def pytest_addoption(parser):
    group = parser.getgroup('dxt compatibility shards')
    group.addoption('--dxt-shard-count', type=int, help='Collect a plan with this many shards')
    group.addoption('--dxt-shard-plan', type=Path, help='Previously collected full-suite plan')
    group.addoption('--dxt-shard-index', type=int, help='Zero-based module shard index')
    group.addoption('--dxt-shard-output', type=Path, help='Plan or execution manifest output')
    group.addoption('--dxt-shard-timings', type=Path, help='Historical module scheduling weights')


def pytest_configure(config):
    if config.getoption('--dxt-shard-output') is not None:
        config.pluginmanager.register(ShardEvidence(config), 'dxt-shard-evidence')


class ShardEvidence:
    def __init__(self, config):
        self.config = config
        self.output = config.getoption('--dxt-shard-output')
        self.result = None
        self.reports = {}

    @pytest.hookimpl(trylast=True)
    def pytest_collection_modifyitems(self, session, config, items):
        nodes = [item.nodeid for item in items]
        source = source_identity(config.rootpath)
        plan_path = config.getoption('--dxt-shard-plan')
        index = config.getoption('--dxt-shard-index')
        try:
            if plan_path is None:
                count = config.getoption('--dxt-shard-count')
                if not config.option.collectonly or count is None or index is not None:
                    raise ValueError('Plan creation requires --collect-only and --dxt-shard-count')
                timing_path = config.getoption('--dxt-shard-timings')
                weights = json.loads(timing_path.read_text())['seconds_by_module'] if timing_path else {}
                plan = make_plan(nodes, count, weights, source)
                write_json(self.output, plan)
                return
            if config.option.collectonly or index is None or config.getoption('--dxt-shard-count'):
                raise ValueError('Execution requires a plan and --dxt-shard-index')
            plan = json.loads(plan_path.read_text())
            validate_plan(plan)
            if source != plan['source']:
                raise ValueError('Source contents changed after plan collection')
            if nodes != plan['collected']:
                raise ValueError('Shard collection differs from the complete suite plan')
            selected = assigned_nodes(plan, index)
            selected_set = set(selected)
            deselected = [item for item in items if item.nodeid not in selected_set]
            items[:] = [item for item in items if item.nodeid in selected_set]
            config.hook.pytest_deselected(items=deselected)
            for item in items:
                item.user_properties.append((NODE_PROPERTY, item.nodeid))
            self.result = {'format_version': FORMAT_VERSION, 'source': source,
                           'runtime': runtime_identity(),
                           'shard_count': plan['shard_count'], 'shard_index': index,
                           'collected': nodes, 'assigned': selected}
        except (OSError, KeyError, TypeError, ValueError) as error:
            raise pytest.UsageError(f'Compatibility shard failed: {error}') from error

    def pytest_runtest_logreport(self, report):
        if self.result is not None:
            self.reports.setdefault(report.nodeid, []).append(report)

    def pytest_sessionfinish(self, session, exitstatus):
        if self.result is None:
            return
        passed = []
        for node, reports in self.reports.items():
            if (len(reports) == 3 and {report.when for report in reports} == {'setup', 'call', 'teardown'}
                    and all(report.passed and not hasattr(report, 'wasxfail') for report in reports)):
                passed.append(node)
        write_json(self.output, dict(self.result, passed=passed, exit_status=int(exitstatus)))
