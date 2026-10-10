"""Genuine DuckDB cursor UUIDs preserve the stock returned-value contract."""
import uuid

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle  # noqa: F401
from test_usability_resource_hooks import setup_pair


FIRST = 'f81d4fae-7dec-11d0-a765-00a0c91e6bf6'
OTHER = 'ffffffff-ffff-4fff-bfff-ffffffffffff'
VALUES = [FIRST, '550e8400-e29b-41d4-a716-446655440000',
          '00000000-0000-0000-0000-000000000000',
          '00000000-0000-0000-c000-000000000000',
          '00000000-0000-0000-e000-000000000000']


def model(body):
    return '{% if execute %}' + body + '{% else %}select 0 as value{% endif %}'


def render(pair, expected):
    actual, reference = [m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert reference['compiled_code'].strip() == "select '" + expected + "' as value"
    assert actual['compiled_code'] == reference['compiled_code']


def test_cursor_uuid_independent_equality_order_and_mapping_keys(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'duckdb')
    query = "select cast('" + FIRST + "' as uuid),cast('" + OTHER + "' as uuid)"
    body = "{% set row=adapter.add_query(" + repr(query) + ",auto_begin=false)[1].fetchone() %}{% set u=row[0] %}{% set other=row[1] %}"
    body += "{% set same=adapter.add_query(" + repr("select cast('" + FIRST + "' as uuid)") + ",auto_begin=false)[1].fetchone()[0] %}"
    body += "{% set keys={u:'original'} %}{% do keys.update({same:'updated'}) %}select '{{ [u==same,u is sameas same,u!=other,u<other,other>u,u<=same,u>=same,keys|length,keys[same],keys.get(u|string,'missing'),u==u.int,u==u|string,keys.get(u.int,'missing')] }}' as value"
    pair.write('models/marts/rendered.sql', model(body))
    render(pair, "[True, False, True, True, True, True, True, 1, 'updated', 'missing', False, False, 'missing']")


def test_cursor_uuid_public_fields_and_variant_version(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'duckdb')
    query = 'select ' + ','.join("cast('" + value + "' as uuid)" for value in VALUES)
    body = "{% set row=adapter.add_query(" + repr(query) + ",auto_begin=false)[1].fetchone() %}{% set result=[] %}{% for u in row %}"
    body += "{% do result.append([u.fields,u.time_low,u.time_mid,u.time_hi_version,u.clock_seq_hi_variant,u.clock_seq_low,u.node,u.time,u.clock_seq,u.variant,u.version,u.bytes_le.hex(),u.bytes.hex(),u.hex,u.urn,u.int,u is number,u is mapping,u is sequence,u is iterable]) %}{% endfor %}select '{{ result }}' as value"
    pair.write('models/marts/rendered.sql', model(body))
    expected = []
    for text in VALUES:
        u = uuid.UUID(text)
        expected.append([u.fields, u.time_low, u.time_mid, u.time_hi_version,
                         u.clock_seq_hi_variant, u.clock_seq_low, u.node, u.time,
                         u.clock_seq, u.variant, u.version, u.bytes_le.hex(),
                         u.bytes.hex(), u.hex, u.urn, u.int, False, False, False, False])
    render(pair, repr(expected))


@pytest.mark.parametrize('expression', ['u<0', 'u<u|string', 'u|length', 'u|list', 'dict(u)', 'u|tojson', 'tojson(u)'])
def test_cursor_uuid_rejects_incompatible_returned_value_operations(tmp_path, configuration_oracle, request, expression):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'duckdb')
    query = "select cast('" + FIRST + "' as uuid)"
    pair.write('models/marts/rendered.sql', model("{% set u=adapter.add_query(" + repr(query) + ",auto_begin=false)[1].fetchone()[0] %}select '{{ " + expression + " }}' as value"))
    pair.invoke('compile', success=False)
