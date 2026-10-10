"""Exact Decimal expressions consume genuine adapter.add_query cursor values."""
import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair


QUERY = """select
cast('0.123456789012345678901234567890' as decimal(38,30)),
cast('1.25' as decimal(20,2)), cast('-7' as decimal(20,0)),
cast('0.0000000' as decimal(20,7)),
cast('123456789012345678901234567890' as decimal(38,0)),
cast('0.1' as decimal(20,1)), cast('10000000000000000000000000000' as decimal(38,0))"""


def model(expression):
    return """{% if execute %}
{% set cursor=adapter.add_query(""" + repr(QUERY) + """, auto_begin=false)[1] %}
{% set row=cursor.fetchone() %}
{% set d=row[0] %}{% set e=row[1] %}{% set n=row[2] %}{% set z=row[3] %}
{% set large=row[4] %}{% set tenth=row[5] %}{% set huge=row[6] %}
select '{{ """ + expression + """ }}' as value
{% else %}select 0 as value{% endif %}"""


POSITIVE = [
    ('traits', "[d is number,d is integer,d is float,d is mapping,d is sequence,d is iterable,d is callable]", '[True, False, False, False, False, False, False]'),
    ('text_scale', "d|string ~ ':' ~ e|string ~ ':' ~ large|string", '0.123456789012345678901234567890:1.25:123456789012345678901234567890'),
    ('repr', '[d,e]', "[Decimal('0.123456789012345678901234567890'), Decimal('1.25')]"),
    ('identity', '[d is sameas d,d is sameas e]', '[True, False]'),
    ('exact_comparison', '[tenth==0.1,tenth<0.1,e==1.25,z==0,z<tenth,large==123456789012345678901234567890]', '[False, True, True, True, True, True]'),
    ('add_subtract', '(d+1)|string ~ ":" ~ (1-d)|string', '1.123456789012345678901234568:0.8765432109876543210987654321'),
    ('multiply', '(d*e)|string', '0.1543209862654320986265432099'),
    ('divide', '(1/e)|string ~ ":" ~ (e/3)|string', '0.8:0.4166666666666666666666666667'),
    ('quotient_remainder', '(n//3)|string ~ ":" ~ (n%3)|string ~ ":" ~ (large%99)|string ~ ":" ~ (d%2)|string', '-2:-1:18:0.1234567890123456789012345679'),
    ('unary_context', '(+d)|string ~ ":" ~ (-d)|string ~ ":" ~ (n|abs)|string', '0.1234567890123456789012345679:-0.1234567890123456789012345679:7'),
    ('zero_truth', "(z|default('empty',true)) ~ ':' ~ (z==0)|string", 'empty:True'),
    ('conversions', '[large|int,n|int,e|float]', '[123456789012345678901234567890, -7, 1.25]'),
    ('numeric_tests', '[n is odd,n is even,d is odd,d is even,large is divisibleby(99),e is divisibleby(tenth)]', '[False, False, False, False, False, False]'),
    ('numeric_keys', "{e:'value'}[1.25] ~ ':' ~ {1:'integer'}[e-e+1]", 'value:integer'),
    ('methods', "e.as_tuple()|string ~ ':' ~ d.quantize(tenth)|string ~ ':' ~ e.copy_negate().copy_abs()|string", 'DecimalTuple(sign=0, digits=(1, 2, 5), exponent=-2):0.1:1.25'),
    ('method_normalize', "(e-e).normalize()|string ~ ':' ~ e.to_integral_value()|string ~ ':' ~ e.adjusted()|string", '0:1:0'),
    ('sum_sort', "([d,e]|sum)|string ~ ':' ~ ([e,d,z]|sort)|string", "1.373456789012345678901234568:[Decimal('0E-7'), Decimal('0.123456789012345678901234567890'), Decimal('1.25')]"),
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('name, expression, expected', POSITIVE)
def test_cursor_decimal_preserves_exact_returned_number_semantics(tmp_path, configuration_oracle, request, adapter, name, expression, expected):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', model(expression))
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert reference['compiled_code'].strip() == "select '" + expected + "' as value"
    assert actual['compiled_code'] == reference['compiled_code']


NEGATIVE = [
    ('float_add', 'd+0.1'), ('float_reverse', '0.1+d'), ('float_multiply', 'd*1.0'),
    ('float_divide', 'd/1.0'), ('string_add', "d+'1'"), ('none_arithmetic', 'd+none'),
    ('quotient_precision', 'huge//1'), ('remainder_precision', 'huge%1'),
    ('zero_division', 'd/z'), ('length', 'd|length'), ('iteration', 'd|list'),
    ('dictionary', 'dict(d)'), ('json_filter', 'd|tojson'), ('json_function', 'tojson(d)'),
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('name, expression', NEGATIVE)
def test_cursor_decimal_rejects_core_invalid_operations(tmp_path, configuration_oracle, request, adapter, name, expression):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', model(expression))
    pair.invoke('compile', success=False)
