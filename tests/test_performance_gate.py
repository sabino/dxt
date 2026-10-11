"""Fault injection for developer performance certification, without a build."""
from collections import defaultdict
import hashlib
import json

import pytest

import check_performance as performance


def write_compilation(target, sql):
    """Emit complete artifacts using the pinned upstream artifact dataclasses."""
    from dbt.artifacts.resources.base import FileHash
    from dbt.artifacts.resources.types import NodeType
    from dbt.artifacts.resources.v1.model import Model
    from dbt.artifacts.schemas.manifest.v12.manifest import ManifestMetadata, WritableManifest
    from dbt.artifacts.schemas.results import RunStatus
    from dbt.artifacts.schemas.run.v5.run import RunResultOutput, RunResultsArtifact, RunResultsMetadata

    node_id = 'model.performance.model_0000'
    model = Model(
        database='warehouse', schema='main', name='model_0000', resource_type=NodeType.Model,
        package_name='performance', path='model_0000.sql', original_file_path='models/model_0000.sql',
        unique_id=node_id, fqn=['performance', 'model_0000'], alias='model_0000',
        checksum=FileHash(name='sha256', checksum='a' * 64), raw_code=sql,
        compiled=True, compiled_code=sql,
    )
    manifest = WritableManifest(
        metadata=ManifestMetadata(project_name='performance', adapter_type='duckdb'),
        nodes={node_id: model}, sources={}, macros={}, docs={}, exposures={}, metrics={}, groups={},
        selectors={}, disabled={}, parent_map={node_id: []}, child_map={node_id: []},
        group_map={}, saved_queries={}, semantic_models={}, unit_tests={},
    ).to_dict(omit_none=False)
    row = RunResultOutput(
        status=RunStatus.Success, timing=[], thread_id='main', execution_time=0.01,
        adapter_response={}, message=None, failures=None, unique_id=node_id,
        compiled=True, compiled_code=sql, relation_name=None,
    )
    results = RunResultsArtifact(
        metadata=RunResultsMetadata(), results=[row], elapsed_time=0.01, args={},
    ).to_dict(omit_none=False)
    target.mkdir(exist_ok=True)
    (target / 'manifest.json').write_text(json.dumps(manifest))
    (target / 'run_results.json').write_text(json.dumps(results))


@pytest.fixture
def compilation_fixture(tmp_path, monkeypatch):
    binary = tmp_path / 'dxt'
    binary.write_bytes(b'developer performance fixture')
    monkeypatch.setattr(performance.shutil, 'which', lambda command: str(tmp_path / 'dbt'))
    calls = []
    counts = defaultdict(int)

    def install(corrupt=None):
        def invoke(arguments, project):
            target = project / arguments[arguments.index('--target-path') + 1]
            engine = target.name.removeprefix('target-')
            phase = 'cold' if counts[engine] % 2 == 0 else 'warm'
            assert target.exists() is (phase == 'warm')
            counts[engine] += 1
            calls.append((engine, phase))
            write_compilation(target, 'select 1 as value')
            if corrupt is not None:
                corrupt(target, engine, phase)
            return 0.25 if engine == 'dxt' else 0.5
        monkeypatch.setattr(performance, 'invoke', invoke)
        return binary, calls

    return install


@pytest.mark.parametrize('phase', ['cold', 'warm'])
@pytest.mark.parametrize('sql', ['select 2 as value', 'select  1 as value'])
def test_incorrect_phase_sql_cannot_be_hidden_by_a_correct_warm_overwrite(compilation_fixture, phase, sql):
    def corrupt(target, engine, observed_phase):
        if engine == 'dxt' and observed_phase == phase:
            write_compilation(target, sql)

    binary, calls = compilation_fixture(corrupt)
    with pytest.raises(AssertionError, match=f'differ in the {phase} performance fixture'):
        performance.measure(binary, models=1, repetitions=2)
    expected = [('dxt', 'cold'), ('dbt', 'cold')]
    if phase == 'warm':
        expected += [('dxt', 'warm'), ('dbt', 'warm')]
    assert calls == expected


@pytest.mark.parametrize('phase', ['cold', 'warm'])
@pytest.mark.parametrize('engine', ['dxt', 'dbt'])
@pytest.mark.parametrize('artifact', ['manifest.json', 'run_results.json'])
def test_each_engine_phase_rejects_full_schema_errors_before_overwrite(compilation_fixture, phase, engine, artifact):
    def corrupt(target, observed_engine, observed_phase):
        if (observed_engine, observed_phase) == (engine, phase):
            path = target / artifact
            value = json.loads(path.read_text())
            if artifact == 'manifest.json':
                del value['nodes']['model.performance.model_0000']['checksum']
            else:
                value['results'][0]['status'] = 'not-a-valid-status'
            path.write_text(json.dumps(value))

    binary, calls = compilation_fixture(corrupt)
    with pytest.raises(AssertionError, match='complete upstream artifact schema'):
        performance.measure(binary, models=1, repetitions=2)
    assert calls[-1] == (engine, phase)
    assert len(calls) == (0 if phase == 'cold' else 2) + (1 if engine == 'dxt' else 2)


@pytest.mark.parametrize('phase', ['cold', 'warm'])
def test_success_status_does_not_certify_missing_compiled_sql(compilation_fixture, phase):
    def corrupt(target, engine, observed_phase):
        if (engine, observed_phase) == ('dxt', phase):
            path = target / 'manifest.json'
            value = json.loads(path.read_text())
            value['nodes']['model.performance.model_0000']['compiled_code'] = None
            path.write_text(json.dumps(value))

    binary, calls = compilation_fixture(corrupt)
    with pytest.raises(AssertionError, match='did not compile every model successfully'):
        performance.measure(binary, models=1, repetitions=2)
    assert calls[-1] == ('dxt', phase)


def test_valid_phase_pairs_preserve_repetition_samples_and_report(compilation_fixture):
    binary, calls = compilation_fixture()
    report = performance.measure(binary, models=1, repetitions=2)
    assert calls == [('dxt', 'cold'), ('dbt', 'cold'), ('dxt', 'warm'), ('dbt', 'warm')] * 2
    assert report['seconds'] == {
        'dxt': {'cold': [0.25, 0.25], 'warm': [0.25, 0.25]},
        'dbt': {'cold': [0.5, 0.5], 'warm': [0.5, 0.5]},
    }
    assert report['native_to_core_ratio'] == {'cold': 0.5, 'warm': 0.5}
    assert report['binary_sha256'] == hashlib.sha256(binary.read_bytes()).hexdigest()
