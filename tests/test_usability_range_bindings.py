"""Returned stock PostgreSQL ranges use genuine native client adaptation."""
import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair


RANGES = [
    ('int4range', '[2,5)'),
    ('int8range', '[9007199254740993,9007199254740999)'),
    ('numrange', '(1.234567890123456789,9.876543210987654321]'),
    ('daterange', '[2024-02-29,2024-03-02)'),
    ('tsrange', '("2024-02-29 12:34:56.123456","2024-03-01 01:02:03.654321"]'),
    ('tstzrange', '["2024-02-29 12:34:56.123456+05:30:26","2024-03-01 01:02:03.654321+05:30:26")'),
]


def range_model(query, bound_query='select pg_typeof(%s)::text, %s::text'):
    return """{% if execute %}
{% do adapter.add_query("set time zone interval '+05:30:26'",auto_begin=false) %}
{% set value=adapter.add_query("""+repr(query)+""",auto_begin=false)[1].fetchone()[0] %}
{% set row=adapter.add_query("""+repr(bound_query)+""",bindings=[value,value],auto_begin=false)[1].fetchone() %}
select '{{ row }}' as value
{% else %}select 0 as value{% endif %}"""


def assert_pair(tmp_path, configuration_oracle, request, query, bound_query=None, *, success=True):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',range_model(query, bound_query) if bound_query else range_model(query))
    manifests=pair.invoke('compile',success=success)
    if success:
        actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in manifests]
        assert actual['compiled_code']==expected['compiled_code']
        return actual['compiled_code']


@pytest.mark.parametrize('range_type,finite',RANGES)
@pytest.mark.parametrize('state',['finite','empty','unbounded'])
def test_returned_range_binding_preserves_stock_scalar_type_and_bounds(tmp_path,configuration_oracle,request,range_type,finite,state):
    raw={'finite':finite,'empty':'empty','unbounded':'(,)'}[state]
    sql=assert_pair(tmp_path,configuration_oracle,request,"select '"+raw+"'::"+range_type)
    expected_type='unknown' if range_type in {'int4range','int8range','numrange'} else range_type
    assert "('"+expected_type+"'," in sql


@pytest.mark.parametrize('range_type,finite',RANGES)
def test_returned_range_arrays_keep_null_empty_and_stock_array_inference(tmp_path,configuration_oracle,request,range_type,finite):
    query="select array['"+finite+"'::"+range_type+",null,'empty'::"+range_type+"]"
    sql=assert_pair(tmp_path,configuration_oracle,request,query)
    expected_type='text[]' if range_type in {'int4range','int8range','numrange'} else range_type+'[]'
    assert "('"+expected_type+"'," in sql


@pytest.mark.parametrize('range_type,raw',[
    ('daterange','(,2024-03-03)'),('daterange','[2024-02-29,)'),
    ('tsrange','(,"2024-03-01 01:02:03.654321"]'),('tsrange','["2024-02-29 12:34:56.123456",)'),
    ('tstzrange','(,"2024-03-01 01:02:03.654321+05:30:26"]'),('tstzrange','["2024-02-29 12:34:56.123456+05:30:26",)'),
])
def test_temporal_range_binding_preserves_one_sided_and_fixed_offset_endpoints(tmp_path,configuration_oracle,request,range_type,raw):
    assert_pair(tmp_path,configuration_oracle,request,"select '"+raw+"'::"+range_type)


def test_numeric_range_binding_retains_numeric_adapter_negative_spacing(tmp_path,configuration_oracle,request):
    sql=assert_pair(tmp_path,configuration_oracle,request,"select '[-5,-1)'::int4range")
    assert '[ -5, -1)' in sql


@pytest.mark.parametrize('typed',[False,True])
def test_range_null_binding_retains_unknown_and_explicit_context(tmp_path,configuration_oracle,request,typed):
    bound='select pg_typeof(%s::daterange)::text, %s::daterange::text' if typed else None
    assert_pair(tmp_path,configuration_oracle,request,'select null::daterange',bound)


@pytest.mark.parametrize('raw',['[-Infinity,Infinity]','[1,Infinity)','[NaN,NaN]'])
def test_returned_nonfinite_numeric_ranges_retain_stock_client_adaptation_error(tmp_path,configuration_oracle,request,raw):
    assert_pair(tmp_path,configuration_oracle,request,"select '"+raw+"'::numrange",success=False)
