"""Mandatory native held-query DB-API and binary transport contract."""
from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair


def test_duckdb_bound_nul_text_and_blob_preserve_lengths(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set r=adapter.add_query('select ?, hex(?)',bindings=['a\\u0000b',fromyaml('!!binary YQD/')],auto_begin=false) %}{% set row=r[1].fetchone() %}select {{ row[0]|length }} as size, '{{ row[1] }}' as bytes{% else %}select 1{% endif %}")
    actual,expected=[manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert 'select 3 as size' in actual['compiled_code']

import pytest


def cursor_model(query, expression, before=''):
    return """{% if execute %}""" + before + """{% set cursor=adapter.add_query(""" + repr(query) + """,auto_begin=false)[1] %}{% set row=cursor.fetchone() %}select '{{ """ + expression + """ }}' as value{% else %}select 0 as value{% endif %}"""


SCALARS = [
    ('integer_precision', "select cast('123456789012345678901234567890' as decimal(38,0)), 42, null", "[row[0]|string,row[1] is integer,row[2] is none]"),
    ('decimal_scale', "select cast('12.340' as decimal(8,3))", "row[0]|string ~ ':' ~ row[0].as_tuple()|string"),
    ('date', "select date '2024-01-02'", "row[0].isoformat() ~ ':' ~ row[0].year|string ~ ':' ~ row[0].month|string"),
    ('time', "select time '12:34:56.123456'", "row[0].isoformat() ~ ':' ~ row[0].microsecond|string"),
    ('timestamp', "select timestamp '1969-12-31 23:59:59.123456'", "row[0].isoformat() ~ ':' ~ row[0].strftime('%Y/%m/%d')"),
    ('timestamp_zone', "select timestamptz '2024-01-02 12:34:56.123456+00'", "row[0].isoformat() ~ ':' ~ row[0].utcoffset()|string"),
    ('interval', "select interval '1 month 2 days 3 microseconds'", "row[0].days|string ~ ':' ~ row[0].seconds|string ~ ':' ~ row[0].microseconds|string"),
    ('array', "select array[1,null,3]", "[row[0],row[0] is mapping,row[0] is sequence,row[0] is iterable]"),
    ('uuid', "select cast('12345678-1234-1234-1234-123456789abc' as uuid)", "row[0]|string"),
]


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('name,query,expression',SCALARS)
def test_original_cursor_scalar_types_and_precision(tmp_path, configuration_oracle, request, adapter, name, query, expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',cursor_model(query,expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('name,query,expression',[
    ('numbers',"select cast('12.340' as decimal(8,3)) as d, cast('1.25' as double precision) as f, 42 as i", "table.rows[0][0]|string ~ ':' ~ table.rows[0][1]|string ~ ':' ~ table.rows[0][1].as_tuple()|string ~ ':' ~ table.rows[0][2] is integer"),
    ('arrays',"select array[1,null,3] as a", "table.rows[0][0]|string ~ ':' ~ table.rows[0][0] is string"),
    ('date',"select date '2024-01-02' as d, timestamp '2024-01-02 12:34:56' as stamp", "table.rows[0][0].isoformat() ~ ':' ~ table.rows[0][1].isoformat()"),
    ('empty',"select 1 as a where false", "table.rows|length ~ ':' ~ table.column_names|list|string"),
])
def test_agate_query_projection_is_distinct_from_original_cursor(tmp_path,configuration_oracle,request,adapter,name,query,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query("+repr(query)+") %}select '{{ "+expression+" }}' as value{% else %}select 0 as value{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_cursor_alias_consumption_and_empty_fetches(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"""{% if execute %}{% set c=adapter.add_query('select 1 as i union all select 2 union all select 3 order by i',auto_begin=false)[1] %}{% set alias=c %}{% set zero=c.fetchmany(0) %}{% set one=alias.fetchone() %}{% set two=c.fetchmany(1) %}{% set tail=alias.fetchall() %}select '{{ [zero,one,two,tail,c.fetchone(),alias.fetchall()] }}' as value{% else %}select 0 as value{% endif %}""")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


DUCK = [
    ('nul_result', "select 'a' || chr(0) || 'b'", "row[0]|length ~ ':' ~ (row[0][1]=='\\u0000')|string"),
    ('blob', "select from_hex('6100ff')", "row[0].hex() ~ ':' ~ row[0]|length ~ ':' ~ row[0]|list|string"),
    ('struct', "select {'name':'x', 'value': [1,null,3]}", "row[0]['name'] ~ ':' ~ row[0]['value']|string"),
    ('map', "select map(['x','y'],[1,2])", "row[0]['x']|string ~ ':' ~ row[0].keys()|list|string"),
    ('union', "select union_value(x:=42)", "row[0]|string ~ ':' ~ row[0] is integer"),
    ('nanoseconds', "select '1969-12-31 23:59:59.999999999'::timestamp_ns", "row[0].isoformat()"),
    ('bit', "select '10101'::bit", "row[0]|string ~ ':' ~ row[0] is string"),
    ('bignum', "select '12345678901234567890123456789012345678901234567890'::bignum", "row[0]|string ~ ':' ~ row[0] is integer"),
    ('description_decimal', "select 12.340::decimal(8,3) as d", "cursor.description[0][1].id ~ ':' ~ cursor.description[0][1].children|string ~ ':' ~ cursor.description[0][2:]|string"),
    ('description_list', "select [1,null,3] as values", "cursor.description[0][1].id ~ ':' ~ cursor.description[0][1].children[0][0] ~ ':' ~ cursor.description[0][1].children[0][1].id"),
    ('description_struct', "select {'x':42} as values", "cursor.description[0][1].id ~ ':' ~ cursor.description[0][1].children[0][0] ~ ':' ~ cursor.description[0][1].children[0][1].id"),
    ('description_primitive', "select 42 as value", "cursor.description[0][1].id ~ ':' ~ cursor.description[0][1]|string"),
    ('description_null', "select null as value", "cursor.description[0][1].id ~ ':' ~ cursor.description[0][1]|string"),
]


@pytest.mark.parametrize('name,query,expression',DUCK)
def test_duckdb_cursor_binary_composites_and_description(tmp_path,configuration_oracle,request,name,query,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',cursor_model(query,expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


POSTGRES = [
    ('binary', "select decode('6100ff','hex')", "row[0].hex() ~ ':' ~ row[0].tobytes().hex() ~ ':' ~ row[0].tolist()|string ~ ':' ~ row[0].format"),
    ('json', "select '{\"integer\":12345678901234567890,\"items\":[1,null,\"é\"]}'::jsonb", "row[0]['integer']|string ~ ':' ~ row[0]['items']|string"),
    ('description', "select 42::integer as i, 'x'::varchar(7) as v, 12.340::numeric(8,3) as d, 1::numeric as n", "cursor.description|string"),
    ('range', "select '[1,5)'::int4range", "row[0]|string ~ ':' ~ [row[0].lower,row[0].upper,row[0].lower_inc,row[0].upper_inc,row[0].isempty,3 in row[0],5 in row[0]]|string"),
    ('range_empty', "select 'empty'::numrange", "[row[0]._bounds,row[0].lower,row[0].upper,row[0].lower_inf,row[0].upper_inf,row[0].lower_inc,row[0].upper_inc,row[0].isempty,row[0]|default('empty',true)]|string"),
    ('range_unbounded', "select '(,)'::numrange", "[row[0].lower_inf,row[0].upper_inf,1000000 in row[0],row[0]|string]|string"),
    ('range_array', "select array['[1,5)'::int4range,'empty'::int4range,null]", "row[0]|string"),
    ('range_date', "select '[2024-01-01,2024-02-01)'::daterange", "row[0].lower.isoformat() ~ ':' ~ row[0].upper.isoformat() ~ ':' ~ row[0].isempty|string"),
]


@pytest.mark.parametrize('name,query,expression',POSTGRES)
def test_postgres_cursor_binary_json_ranges_and_description(tmp_path,configuration_oracle,request,name,query,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',cursor_model(query,expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('query,expression',[("select 42",'cursor.fetchmany(-1)'),("select 42",'cursor.description[0][1].children')])
def test_duckdb_cursor_rejects_driver_invalid_operations(tmp_path,configuration_oracle,request,query,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',cursor_model(query,expression))
    pair.invoke('compile',success=False)

@pytest.mark.parametrize('query',[
    "select union_value(num:=42)::union(num integer,txt varchar) as v union all select union_value(txt:='005')::union(num integer,txt varchar)",
    "select union_value(flag:=false)::union(flag boolean,num integer) as v union all select union_value(num:=1)::union(flag boolean,num integer)",
    "select union_value(d:=date '2024-01-02')::union(d date,stamp timestamp) as v union all select union_value(stamp:=timestamp '2024-01-02 03:04:05')::union(d date,stamp timestamp)",
])
def test_duckdb_agate_infers_complete_union_column(tmp_path,configuration_oracle,request,query):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query("+repr(query)+") %}select '{{ [table.rows[0][0],table.rows[1][0]] }}' as value{% else %}select 0 as value{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


def test_postgres_column_description_attributes_and_sequence_fields(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    expression="[cursor.description[0].name,cursor.description[0].type_code,cursor.description[0].display_size,cursor.description[0].internal_size,cursor.description[0].precision,cursor.description[0].scale,cursor.description[0].null_ok,cursor.description[0]|list,cursor.description[0] is mapping,cursor.description[0] is sequence,cursor.description[0] is iterable]|string"
    pair.write('models/marts/rendered.sql',cursor_model("select 12.340::numeric(8,3) as d",expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_agate_driver_integer_preserves_its_integer_type(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query('select 42 as i') %}select '{{ [table.rows[0][0] is integer, table.rows[0][0]+1] }}' as value{% else %}select 0 as value{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query('select 42 as i') %}select '{{ table.rows[0][0].as_tuple() }}' as value{% else %}select 0 as value{% endif %}")
    pair.invoke('compile',success=False)


def test_duckdb_fixed_array_cursor_is_tuple_and_agate_is_json_text(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    query="select [1,2,3]::integer[3] as value"
    pair.write('models/marts/rendered.sql',cursor_model(query,"[row[0],row[0] is mapping,row[0] is sequence]|string"))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query("+repr(query)+") %}select '{{ [table.rows[0][0],table.rows[0][0] is string] }}' as value{% else %}select 0 as value{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


def test_duckdb_nonhashable_map_keys_have_driver_key_value_lists(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    query="select map([[1,2]],['x']) as v"
    pair.write('models/marts/rendered.sql',cursor_model(query,"row[0]|string"))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query("+repr(query)+") %}select '{{ table.rows[0][0] }}' as value{% else %}select 0 as value{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('method',['fetchone','fetchmany','fetchall'])
def test_postgres_cursor_rejects_fetch_without_result_description(tmp_path,configuration_oracle,request,method):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    query='create table no_cursor_results (i integer)'
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set cursor=adapter.add_query("+repr(query)+",auto_begin=false)[1] %}select '{{ cursor."+method+"() }}' as value{% else %}select 0 as value{% endif %}")
    pair.invoke('compile',success=False)


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_run_query_consumes_its_driver_cursor_without_changing_postgres_saved_cursor(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query('select 1 as i',auto_begin=false)[1] %}{% set table=run_query('select 2 as i') %}select '{{ table.rows[0][0] }}:{{ c.fetchone() }}' as value{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert ('2:None' if adapter=='duckdb' else '2:(1,)') in actual['compiled_code']


def test_duckdb_decimal_map_key_is_valid_original_cursor_but_not_agate_json(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    query='select map([1.25::decimal(8,2)],[42]) as v'
    pair.write('models/marts/rendered.sql',cursor_model(query,'row[0]|string'))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert "Decimal('1.25'): 42" in actual['compiled_code']
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query("+repr(query)+") %}select '{{ table.rows[0][0] }}'{% else %}select 0{% endif %}")
    pair.invoke('compile',success=False)


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('query',[
    'select 1 as x,2 as x',
    'select 1 as x,2 as x,3 as x_2,4 as x',
])
def test_agate_renames_duplicates_and_keeps_original_cursor_description(tmp_path,configuration_oracle,request,adapter,query):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query("+repr(query)+",auto_begin=false)[1] %}{% set original=c.description|map(attribute='name')|list if '"+adapter+"'=='postgres' else c.description|map(attribute=0)|list %}{% set table=run_query("+repr(query)+") %}select '{{ [original,table.column_names|list,table.rows[0]|list] }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


def test_duckdb_type_equality_and_dictionary_keys_use_driver_contract(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    expression="[cursor.description[0][1]=='integer','InTeGeR'==cursor.description[0][1],cursor.description[0][1]=='INT',cursor.description[0][1]==' INTEGER',{cursor.description[0][1]:'typed'}['INTEGER'],{'INTEGER':'text'}[cursor.description[0][1]],{cursor.description[0][1]:'typed'}.get('integer','missing')]|string"
    pair.write('models/marts/rendered.sql',cursor_model('select 42 as value',expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert "[True, True, False, False, 'typed', 'text', 'missing']" in actual['compiled_code']


PARAMETERS = [
    ('integers','[1,2]',True,True),
    ('tuple','(1,2)',True,True),
    ('empty_list','[]',True,True),
    ('empty_tuple','()',True,False),
    ('nulls','[none,none]',True,True),
    ('booleans_integers','[true,2]',True,False),
    ('integer_text',"[1,'a']",True,False),
    ('nested','[[1,2],[3,4]]',True,True),
    ('nested_nulls','[[1,none],[2,3]]',True,True),
    ('dictionary',"{'a':1,'s':'é'}",True,False),
    ('empty_dictionary','{}',True,False),
    ('integer_dictionary_keys',"{1:'a',2:'b'}",True,False),
    ('map_dictionary',"{'key':[1,2],'value':['a','b']}",True,False),
    ('unequal_map_lists',"{'key':[1,2],'value':['a']}",True,False),
    ('tuple_mixed',"(1,'a')",True,True),
    ('quoted_field',"{'x\" ); drop table target; --':'a\\u0000b'}",True,False),
]


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('name,binding,duckdb_success,postgres_success',PARAMETERS)
def test_recursive_query_parameters_preserve_driver_shapes_types_and_errors(tmp_path,configuration_oracle,request,adapter,name,binding,duckdb_success,postgres_success):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    placeholder='?' if adapter=='duckdb' else '%s'
    query=('select typeof('+placeholder+') as kind, '+placeholder+' as value') if adapter=='duckdb' else ('select pg_typeof('+placeholder+')::text as kind, '+placeholder+' as value')
    body="{% if execute %}{% set value="+binding+" %}{% set c=adapter.add_query("+repr(query)+",bindings=[value,value],auto_begin=false)[1] %}{% set row=c.fetchone() %}select '{{ [row[0],row[1],c.description[1][1]|string] }}'{% else %}select 0{% endif %}"
    pair.write('models/marts/rendered.sql',body)
    success=duckdb_success if adapter=='duckdb' else postgres_success
    if not success:
        pair.invoke('compile',success=False)
    else:
        actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
        assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_named_parameter_bindings_preserve_repeated_names_and_literal_tokens(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    query="select $value, $value, '$value', $$ $value $$ /* $value */" if adapter=='duckdb' else "select %(value)s, %(value)s, '%%(value)s' /* %%(value)s */"
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query("+repr(query)+",bindings={'value':'é'},auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('query,bindings',[
    ('select {slot}',"{'missing':1}"),
    ('select {slot}',"[1,2]"),
    ('select {slot}',"'value'"),
])
def test_query_parameters_reject_missing_names_arity_and_noncollections(tmp_path,configuration_oracle,request,adapter,query,bindings):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    query=query.format(slot='$value' if adapter=='duckdb' else '%(value)s')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query("+repr(query)+",bindings="+bindings+",auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    pair.invoke('compile',success=False)


@pytest.mark.parametrize('sql_type',['date','timestamp','timestamp_s','timestamp_ms','timestamp_ns','timestamptz'])
def test_duckdb_cursor_temporal_infinities_use_python_boundaries(tmp_path,configuration_oracle,request,sql_type):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    query="select 'infinity'::"+sql_type+", '-infinity'::"+sql_type
    pair.write('models/marts/rendered.sql',cursor_model(query,"[row[0].isoformat(),row[1].isoformat(),row[0].tzinfo if '"+sql_type+"'!='date' else none]|string", "{% do adapter.add_query(\"set timezone='Europe/Berlin'\",auto_begin=false) %}"))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_named_bindings_extra_keys_follow_real_driver_policy(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    query='select $value' if adapter=='duckdb' else 'select %(value)s'
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query("+repr(query)+",bindings={'value':42,'unused':2},auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    if adapter=='duckdb':
        pair.invoke('compile',success=False)
    else:
        actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
        assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('expression',[
    '[cursor.description[0]==cursor.description[0]|list,cursor.description[0]==(cursor.description[0]|list)|first,cursor.description[0]==cursor.description[0][:],cursor.description[0][-1],cursor.description[0][1:3]]|string',
    '[cursor.description[0] == cursor.description[1],cursor.description[0] < cursor.description[1],cursor.description[0] == (\'a\',23,none,4,none,none,none)]|string',
])
def test_postgres_column_descriptor_comparisons_and_slicing(tmp_path,configuration_oracle,request,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',cursor_model('select 1::integer as a,2::integer as b',expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('expression',['{cursor.description[0]:1}','cursor.description[0].count(1)','cursor.description[0].index(1)','cursor.description[0]+(1,)','cursor.description[0]*2'])
def test_postgres_column_descriptor_rejects_tuple_only_operations(tmp_path,configuration_oracle,request,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',cursor_model('select 1::integer as a',expression))
    pair.invoke('compile',success=False)


@pytest.mark.parametrize('expression',[
    '[row[0].readonly,row[0].format,row[0].shape,row[0].strides,row[0].suboffsets,row[0].c_contiguous,row[0].f_contiguous,row[0].contiguous,row[0].obj is mapping,row[0].obj is iterable,row[0].obj|default(false,true) != false]|string',
    '[row[0]==row[0].tobytes(),row[0]==row[0].cast(\'B\'),row[0]==row[0].cast(\'c\'),row[0].cast(\'B\')==row[0].tobytes(),row[0].cast(\'B\').tolist(),row[0].cast(\'b\').tolist(),row[0].obj is sameas row[0].cast(\'c\').obj]|string',
])
def test_postgres_binary_memoryview_buffer_metadata_and_comparisons(tmp_path,configuration_oracle,request,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',cursor_model("select decode('6100ff','hex')",expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('expression',['row[0].obj|length','row[0].obj|list'])
def test_postgres_memory_chunk_rejects_sequence_operations(tmp_path,configuration_oracle,request,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',cursor_model("select decode('6100ff','hex')",expression))
    pair.invoke('compile',success=False)


SCALAR_PARAMETERS = [
    ('none','none',True,True),
    ('text',"'é'",True,True),
    ('boolean','true',True,True),
    ('unsigned_integer','18446744073709551615',True,True),
    ('signed_overflow','-9223372036854775809',True,True),
    ('wide_integer','123456789012345678901234567890',True,True),
    ('float','1.25',True,True),
    ('binary',"fromyaml('!!binary YQD/')",True,True),
    ('nul_text',"'a\\u0000b'",True,False),
    ('date','modules.datetime.date(2024,2,29)',True,True),
    ('time','modules.datetime.time(12,34,56,123456)',True,True),
    ('time_zone','modules.datetime.time(12,34,56,123456,tzinfo=modules.pytz.FixedOffset(330))',True,True),
    ('timestamp','modules.datetime.datetime(2024,2,29,12,34,56,123456)',True,True),
    ('timestamp_zone','modules.datetime.datetime(2024,2,29,12,34,56,123456,tzinfo=modules.pytz.FixedOffset(330))',True,True),
    ('interval','modules.datetime.timedelta(days=2,seconds=3,microseconds=4)',True,True),
]


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('name,binding,duckdb_success,postgres_success',SCALAR_PARAMETERS)
def test_scalar_query_binding_types_precision_binary_and_timezone(tmp_path,configuration_oracle,request,adapter,name,binding,duckdb_success,postgres_success):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    slot='?' if adapter=='duckdb' else '%s'
    query='select '+('typeof('+slot+')' if adapter=='duckdb' else 'pg_typeof('+slot+')::text')+' as kind,'+slot+' as value'
    shown="[row[0],row[1].hex(),row[1].format,c.description[1][1]|string]" if adapter=='postgres' and name=='binary' else "[row,c.description[1][1]|string]"
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set value="+binding+" %}{% set c=adapter.add_query("+repr(query)+",bindings=[value,value],auto_begin=false)[1] %}{% set row=c.fetchone() %}select '{{ "+shown+" }}'{% else %}select 0{% endif %}")
    if not (duckdb_success if adapter=='duckdb' else postgres_success):
        pair.invoke('compile',success=False)
    else:
        actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
        assert actual['compiled_code']==expected['compiled_code']


def test_postgres_memory_chunk_index_is_sandbox_undefined(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',cursor_model("select decode('6100ff','hex')",'row[0].obj[0] is undefined'))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert 'True' in actual['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('kind',['datetime','time'])
def test_fractional_timezone_offset_parameter_follows_actual_driver_acceptance(tmp_path,configuration_oracle,request,adapter,kind):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    slot='?' if adapter=='duckdb' else '%s'
    query='select '+slot
    value="modules.datetime.datetime.fromisoformat('2024-02-29T12:34:56+05:30:26.000007')"
    if kind=='time':
        value="modules.datetime.time(12,34,56,123456,tzinfo="+value+".tzinfo)"
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set value="+value+" %}{% set c=adapter.add_query("+repr(query)+",bindings=[value],auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    if adapter=='postgres' or kind=='time':
        pair.invoke('compile',success=False)
    else:
        actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
        assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('query,bindings',[
    ('select ?2 as b, ?1 as a','[[1,2],[3,4]]'),
    ('select ?1 as a, ?1 as b','[[1,2]]'),
    ('select $2 as b, $1 as a','[[1,2],[3,4]]'),
])
def test_duckdb_recursive_indexed_parameters_reorder_and_repeat(tmp_path,configuration_oracle,request,query,bindings):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query("+repr(query)+",bindings="+bindings+",auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


def test_duckdb_type_indexing_and_bounded_iteration_return_notimplemented(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    expression="[cursor.description[0][1][0]|string,cursor.description[0][1][-1] is sameas cursor.description[0][1][none],cursor.description[0][1][[]] is sameas cursor.description[0][1][:],cursor.description[0][1].id,cursor.description[0][1] is iterable,cursor.description[0][1] is sequence,(cursor.description[0][1]|first) is sameas cursor.description[0][1][0],modules.itertools.islice(cursor.description[0][1],2)|list|string]|string"
    pair.write('models/marts/rendered.sql',cursor_model('select 42',expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('query,key',[
    ("select {'x':42}",'x'),
    ("select union_value(x:=42)::union(x integer,y varchar)",'y'),
    ("select map(['a'],[1])",'key'),
    ("select [1,2]",'child'),
])
def test_duckdb_nested_type_named_index_returns_its_child_type(tmp_path,configuration_oracle,request,query,key):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',cursor_model(query,"cursor.description[0][1]["+repr(key)+"]|string"))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('key',['id','missing'])
def test_duckdb_primitive_type_string_index_is_a_child_lookup_error(tmp_path,configuration_oracle,request,key):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',cursor_model('select 42',"cursor.description[0][1]["+repr(key)+"]|string"))
    pair.invoke('compile',success=False)


def test_duckdb_named_bindings_last_case_insensitive_key_wins(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query('select $foo as a,$FOO as b',bindings={'foo':[1],'FOO':[2]},auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert '([2], [2])' in actual['compiled_code']


def test_duckdb_recursive_indexed_bindings_reject_unreferenced_values(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query('select ?2',bindings=[[1],[2]],auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    pair.invoke('compile',success=False)


def test_duckdb_mixed_indexed_parameters_advance_unnumbered_index(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query('select ?1[1] + ?[1] + ?2[1]',bindings=[[1],[2]],auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert '(5,)' in actual['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('receiver',['table.rows[0]','table.columns[0]'])
def test_outer_bindings_accept_actual_sized_agate_row_and_column(tmp_path,configuration_oracle,request,adapter,receiver):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    slot='?' if adapter=='duckdb' else '%s'
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set table=run_query('select 7 as n') %}{% set c=adapter.add_query("+repr('select '+slot)+",bindings="+receiver+",auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_outer_bindings_reject_unsized_iterator_without_materializing_it(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    slot='?' if adapter=='duckdb' else '%s'
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query("+repr('select '+slot)+",bindings=modules.itertools.chain([7]),auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    pair.invoke('compile',success=False)


def test_postgres_empty_bytea_keeps_distinct_chunks_and_equal_empty_views(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    expression="[row[0].obj is sameas row[1].obj,row[0] == fromyaml('!!binary \"\"'),row[0] == row[0].cast('B'),{row[0]:1,fromyaml('!!binary \"\"'):2}|length]|string"
    pair.write('models/marts/rendered.sql',cursor_model("select decode('','hex'),decode('','hex')",expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert '[False, True, True, 1]' in actual['compiled_code']


def test_postgres_memoryview_slice_and_cast_retain_original_chunk_size(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    expression="[(row[0][1:].obj|string)==(row[0][1:].cast('B').obj|string),row[0].obj is sameas row[0][1:].cast('B').obj]|string"
    pair.write('models/marts/rendered.sql',cursor_model("select decode('6100ff','hex')",expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert '[True, True]' in actual['compiled_code']


@pytest.mark.parametrize('query',[
    "select {'select':42,'normal':3,'NULL':1,'from':2}",
    "select struct_pack(\"key\":=42,\"name\":=1,\"user\":=2,\"value\":=3,\"integer\":=4,\"time\":=5,\"left\":=6)",
    "select union_value(\"select\":=42)",
])
def test_duckdb_nested_type_labels_quote_all_keyword_categories(tmp_path,configuration_oracle,request,query):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    expression="[cursor.description[0][1]|string,cursor.description[0][1].children|string,{cursor.description[0][1]:1}[cursor.description[0][1]|string]]|string"
    pair.write('models/marts/rendered.sql',cursor_model(query,expression))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('keyword',['size','unknown'])
def test_cursor_fetchmany_validates_keyword_names(tmp_path,configuration_oracle,request,adapter,keyword):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query('select 7',auto_begin=false)[1] %}select '{{ c.fetchmany("+keyword+"=1) }}'{% else %}select 0{% endif %}")
    if keyword=='unknown':
        pair.invoke('compile',success=False)
    else:
        actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
        assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('query,bindings',[
    ('select $é', "{'é':7}"),
    ('select 1 as a$x, $x', "{'x':7}"),
    ('select 1 as a$1, ?', '[[1]]'),
    ('select $1', "{'1':[42]}"),
    ('select ?1', "{'1':[42]}"),
    ('select ?', "{'1':[42]}"),
    ('select $2,$1,$2', "{'1':[11],'2':[22]}"),
])
def test_duckdb_parameter_tokens_preserve_unicode_identifiers_and_numeric_mapping_slots(tmp_path,configuration_oracle,request,query,bindings):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query("+repr(query)+",bindings="+bindings+",auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


def test_duckdb_parameter_mapping_rejects_mixed_named_and_numbered_slots(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query('select $name,$1',bindings={'name':7,'1':7},auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    pair.invoke('compile',success=False)


def memory_model(expression,setup='',hex_bytes='01000000feffffff0300000004000000'):
    code=cursor_model("select decode('"+hex_bytes+"','hex')",expression)
    return code.replace('{% set row=cursor.fetchone() %}', '{% set row=cursor.fetchone() %}'+setup)


@pytest.mark.parametrize('format',['c','b','B','?','h','H','i','I','l','L','q','Q','n','N','e','f','d','P','@i'])
def test_postgres_memoryview_native_numeric_formats_and_typed_values(tmp_path,configuration_oracle,request,format):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    setup="{% set view=row[0].cast("+repr(format)+") %}"
    expression="[view.format,view.itemsize,view.shape,view.strides,view.ndim,view.nbytes,view.tolist(),view.tobytes().hex(),view.obj is sameas row[0].obj]|string"
    pair.write('models/marts/rendered.sql',memory_model(expression,setup))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('order',['C','F','A',None])
def test_postgres_memoryview_multidimensional_order_and_index(tmp_path,configuration_oracle,request,order):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    setup="{% set view=row[0].cast('i',shape=[2,2]) %}"
    expression="[view.tolist(),view[1,0],view[::-1].tolist(),view.shape,view.strides,view.c_contiguous,view.f_contiguous,view.tobytes(order="+('none' if order is None else repr(order))+").hex()]|string"
    pair.write('models/marts/rendered.sql',memory_model(expression,setup))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


def test_postgres_memoryview_scalar_and_release_aliases_preserve_buffer_identity(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    setup="{% set scalar=row[0].cast('i',shape=()) %}{% set peer=scalar.toreadonly() %}{% set alias=scalar %}{% set release=scalar.release %}{% do release() %}{% do release() %}"
    expression="[peer.tolist(),peer[()],peer.shape,peer.ndim,peer.nbytes,peer.obj is sameas row[0].obj,scalar==alias,scalar==peer,'released memory' in scalar|string]|string"
    pair.write('models/marts/rendered.sql',memory_model(expression,setup,'01000000'))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('expression,setup',[
    ("row[0].cast('<i')",''),
    ("row[0].cast('i',unknown=1)",''),
    ("row[0].cast('i',shape=[0])",''),
    ("row[0].cast('i',shape=[-1])",''),
    ("row[0].cast('i',shape=[3])",''),
    ("row[0].cast('i',shape=[4.0])",''),
    ("row[0].cast('i',shape=none)",''),
    ("row[0].cast('i').cast('f')",''),
    ("row[0].tobytes(order='K')",''),
    ("row[0].tobytes(order='c')",''),
    ("row[0].tobytes(order=1)",''),
    ("row[0].tobytes(unknown=1)",''),
    ('saved()',"{% set saved=row[0].tobytes %}{% do row[0].release() %}"),
    ('row[0].format',"{% do row[0].release() %}"),
    ('row[0]|length',"{% do row[0].release() %}"),
    ('row[0]|list',"{% do row[0].release() %}"),
    ('row[0][0]',"{% do row[0].release() %}"),
    ('row[0]|length',"{% set row=[row[0].cast('i',shape=())] %}"),
])
def test_postgres_memoryview_invalid_formats_shapes_orders_and_released_aliases(tmp_path,configuration_oracle,request,expression,setup):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    scalar_bytes='01000000' if 'shape=()' in setup else '01000000feffffff0300000004000000'
    pair.write('models/marts/rendered.sql',memory_model(expression,setup,scalar_bytes))
    pair.invoke('compile',success=False)


@pytest.mark.parametrize('value,success',[
    ('row[0]',True),
    ("row[0].cast('i')",True),
    ("row[0].cast('i',shape=[2,2])",True),
    ('row[0][::2]',False),
    ('row[0][::-1]',False),
    ('row[0]',False),
])
def test_postgres_memoryview_binding_uses_live_contiguous_buffer(tmp_path,configuration_oracle,request,value,success):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    setup="{% do row[0].release() %}" if value=='row[0]' and not success else ''
    setup+="{% set rebound=adapter.add_query('select %s',bindings=["+value+"],auto_begin=false)[1].fetchone() %}"
    pair.write('models/marts/rendered.sql',memory_model('rebound[0].hex()',setup))
    if success:
        actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
        assert actual['compiled_code']==expected['compiled_code']
    else:
        pair.invoke('compile',success=False)


@pytest.mark.parametrize('bindings',['[1]','[[1]]'])
def test_duckdb_named_parameter_rejects_outer_positional_sequence(tmp_path,configuration_oracle,request,bindings):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set c=adapter.add_query('select $name',bindings="+bindings+",auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    pair.invoke('compile',success=False)


def test_postgres_memoryview_jinja_subscriptions_preserve_tuple_indices_and_missing_fallback(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    setup="{% set nd=row[0].cast('i',shape=[2,2]) %}{% set zero=row[0][:4].cast('i',shape=()) %}"
    expression="[nd[1,0],nd['format'],nd['missing'] is undefined,nd[99,0] is undefined,row[0][99] is undefined,zero[0] is undefined,zero['format'],zero[()]]|string"
    pair.write('models/marts/rendered.sql',memory_model(expression,setup))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('number',['NaN','Infinity','-Infinity'])
def test_duckdb_agate_nonfinite_decimal_rebinding_uses_stock_float_adaptation(tmp_path,configuration_oracle,request,number):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    query="select '"+number+"'::double as value"
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set value=run_query("+repr(query)+").rows[0][0] %}{% set c=adapter.add_query('select typeof(?),?',bindings=[value,value],auto_begin=false)[1] %}select '{{ c.fetchone() }}'{% else %}select 0{% endif %}")
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('query',[
    "select date '10000-01-01'",
    "select date '0001-01-01 (BC)'",
    "select timestamp '10000-01-01 00:00:00'",
    "select [date '10000-01-01',date '0001-01-01 (BC)']",
])
def test_duckdb_finite_date_outside_python_years_keeps_actual_cursor_string(tmp_path,configuration_oracle,request,query):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    pair.write('models/marts/rendered.sql',cursor_model(query,'[row[0],row[0] is string]|string'))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('raw_hex,setup,expression',[
    ('',"{% do row[0].release() %}",'row[0]|select|list'),
    ('',"{% do row[0].release() %}","row[0]|map('string')|list"),
    ('01000000',"{% do row[0].release() %}",'[row[0]]|select|list'),
    ('01000000',"{% set row=[row[0].cast('i',shape=[])] %}",'[row[0]]|select|list'),
])
def test_postgres_memoryview_lazy_filters_check_released_and_scalar_truthiness(tmp_path,configuration_oracle,request,raw_hex,setup,expression):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',memory_model(expression,setup,raw_hex))
    pair.invoke('compile',success=False)


@pytest.mark.parametrize('timezone',['UTC','America/New_York'])
@pytest.mark.parametrize('timestamp',['10000-01-01 00:00:00+00','10000-06-01 12:34:56.123456+00'])
def test_duckdb_outside_year_range_timestamptz_preserves_driver_utc_string(tmp_path,configuration_oracle,request,timezone,timestamp):
    pair=setup_pair(tmp_path,configuration_oracle,request,'duckdb')
    setup="{% do adapter.add_query("+repr("set timezone='"+timezone+"'")+",auto_begin=false) %}"
    pair.write('models/marts/rendered.sql',cursor_model("select timestamptz '"+timestamp+"'",'[row[0],row[0] is string]|string',setup))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('method',['tobytes','tolist','cast','toreadonly','release','hex'])
def test_postgres_saved_memoryview_method_rendering_preserves_receiver_identity(tmp_path,configuration_oracle,request,method):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    setup="{% set saved=row[0]."+method+" %}{% set peer=row[0].cast('B') %}"
    prefix='<built-in method '+method+' of memoryview object at 0x'
    expression="[(saved|string).startswith("+repr(prefix)+"),(saved|string).endswith('>'),modules.re.search('0x[0-9a-f]+',saved|string).group(0)==modules.re.search('0x[0-9a-f]+',row[0]|string).group(0),(row[0]."+method+"|string)==(saved|string),([saved]|string).startswith("+repr('['+prefix)+"),(peer."+method+"|string)!=(saved|string)]|string"
    pair.write('models/marts/rendered.sql',memory_model(expression,setup))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert '[True, True, True, True, True, True]' in actual['compiled_code']


def test_postgres_saved_memoryview_method_rendering_remains_stable_after_release(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    setup="{% set saved=row[0].tobytes %}{% set before=saved|string %}{% do row[0].release() %}"
    expression="[(saved|string)==before,(saved|string).startswith('<built-in method tobytes of memoryview object at 0x')]|string"
    pair.write('models/marts/rendered.sql',memory_model(expression,setup))
    actual,expected=[m['nodes']['model.configuration_fixture.rendered'] for m in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert '[True, True]' in actual['compiled_code']
