"""Native str.format fields used by unchanged dbt SQL macros."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import compare, write_project, ROOT, DXT


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "'{} {}'.format(1,1.0)",
    "'{1} {0}'.format('a','b')",
    "'{name} {count}'.format(name='é',count=9007199254740993)",
    "'{{{0}}}'.format('column')",
    "'{{}}'.format()",
    "'{} {x}'.format('a',x='b')",
    "'{x} {}'.format('a',x='b')",
    "'{x!s}:{x!r}:{x!a}'.format(x='é')",
    "'{0[item]}:{0[name]}'.format({'item':1,'name':'foo'})",
    "'{0[1]}'.format((1,2))",
    "'{0.column}'.format(api.Column('foo','integer'))",
    "'{}'.format(this)",
    "'{schema}.{identifier}'.format(**{'schema':'main','identifier':'input'})",
    "'{0:}'.format(1.0)",
    "'{} {} {}'.format(*[true,none,(1,)])",
    "'{:>8s}'.format('SQL')",
    "'{:<8}'.format('SQL')",
    "'{:^8}'.format('SQL')",
    "'{:*^8}'.format('SQL')",
    "'{:🦆^7.2s}'.format('é好😀')",
    "'{:.2s}'.format('é好😀')",
    "'{:05}'.format('é好😀')",
    "'{:>05}'.format('SQL')",
    "'{: >05}'.format('SQL')",
    "'{!r:>10}'.format('é')",
    "'{!a:^12}'.format('é好')",
    "'{!s:.3}'.format([1,2])",
    "'{:d}:{:+d}:{: d}'.format(42,42,42)",
    "'{:05d}:{:05d}'.format(42,-42)",
    "'{:0=8d}:{:>08d}'.format(-42,-42)",
    "'{:*^9d}'.format(-42)",
    "'{:b}:{:#b}:{:o}:{:#o}:{:x}:{:#X}'.format(255,255,255,255,255,255)",
    "'{:#010x}:{:#010x}'.format(42,-42)",
    "'{:_d}:{:,d}'.format(1234567890,1234567890)",
    "'{:010,}:{:010,}'.format(1234,-1234)",
    "'{:010_}:{:010_}'.format(1234,-1234)",
    "'{:#012_X}'.format(11259375)",
    "'{:_b}:{:_o}:{:_x}'.format(65535,65535,11259375)",
    "'{:d}:{:#x}'.format(2**100,2**100)",
    "'{:c}:{:c}'.format(65,128512)",
    "'{:n}'.format(123456)",
    "'{:05d}:{:.2f}'.format(true,false)",
    "'{:.2f}:{:.2f}:{:.2f}'.format(2.675,2.685,2.5)",
    "'{:+010.2f}:{:010.2f}'.format(12.25,-12.25)",
    "'{:,.2f}:{:015,.2f}'.format(12345.5,12345.5)",
    "'{:.3e}:{:.3E}'.format(12345.5,0.00123)",
    "'{:.3g}:{:#.3g}:{:.3G}'.format(12345.5,12.0,0.00123)",
    "'{:.0%}:{:.2%}'.format(0.125,0.125)",
    "'{:z.2f}:{:z.2e}:{:+z.2f}'.format(-0.0001,-0.0,-0.0001)",
    "'{:10}:{:,}:{:#}'.format(12.0,1000000.0,1e20)",
    "'{:.0}:{:.2}:{:.2}:{:.3}'.format(0.0,9.99,12.0,1000.0)",
    "'{:.2f}:{:.3g}'.format(9007199254740993,9007199254740993)",
    "'{:n}:{:.3n}'.format(12345.5,12.345)",
    "'{:+F}:{:G}:{:%}'.format(var('inf','inf')|float,var('nan','nan')|float,var('inf','inf')|float)",
    "'{:.1f}:{:*^15.2f}'.format((-1)**0.5,(-1)**0.5)",
    "'{:+.3e}:{:#}'.format((-1)**0.5,(-1)**0.5)",
    "'{:n}:{:.3n}'.format((-1)**0.5,(-1)**0.5)",
    "'{:05c}:{:0=5c}'.format(65,65)",
    "'{:012,.2e}'.format(12345678.0)",
    "'{0!r:{1}}'.format(1,'04')",
    "'{0:{width}.{precision}f}'.format(1.23456,width=10,precision=3)",
    "'{0:{1}.{2}f}'.format(1.2,8,3)",
    "'{:{}.{}}'.format(12.345,8,4)",
    "'{:{}} {}'.format(42,'04d','done')",
    "'{0[{1}]}'.format({'{1}':'literal-index'})",
    "'{0[x:y]}:{0[x!y]}'.format({'x:y':1,'x!y':2})",
    "'{0[01]}:{0[١]}'.format({1:'integer','1':'string'})",
    "'{١}:{٠}'.format('first','second')",
    "'{:٥d}'.format(12)",
    "'{0[a][1].real:.1f}'.format({'a':(0,2.5)})",
    "'{0[1]}'.format('é好😀')",
    "'{0[9]}:{0[missing]}:{0.missing}'.format({})",
    "'{0[missing]!r}:{0[missing]!a}'.format({})",
    "'{0.__class__}:{0[_private]}'.format({'__class__':'hidden','_private':'data'})",
    "'{0[__class__]}'.format({'__class__':'dictionary-data'})",
    "'{0._private}:{0.__dict__}'.format({'_private':'data','__dict__':'dict-key'})",
    "'{0.__mro__}:{0.__subclasses__}:{0.__globals__}:{0.__code__}'.format({'__mro__':'m','__subclasses__':'s','__globals__':'g','__code__':'c'})",
    "'{0.__init__}:{0.__str__}:{0[__init__]}'.format({'__init__':'data','__str__':'data'})",
    "'{0.schema:>8}:{0.identifier:^10}'.format(this)",
    "'{:%Y-%m-%d}:{:%H:%M:%S}'.format(fromyaml('2024-01-02'),fromyaml('2024-01-02T03:04:05.123Z'))",
])
def test_native_string_format_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", [
    "'{} {0}'.format(1)", "'{'.format(1)", "'}'.format()",
    "'{missing}'.format()", "'{2}'.format(1)", "'{0!z}'.format(1)",
    "'{0} {}'.format(1)", "'{0:{}}'.format(1,2)",
    "'{0:{1:{2}}}'.format(1,2,3)", "'{0:'.format(1)",
    "'{0!}'.format(1)", "'{0..x}'.format(1)", "'{0[]}'.format({})",
    "'{0[a]x}'.format({'a':1})", "'{0[a}'.format({'a':1})",
    "'{:d}'.format('1')", "'{:q}'.format(1)", "'{:.2d}'.format(1)",
    "'{:+s}'.format('s')", "'{:=10s}'.format('s')",
    "'{:#s}'.format('s')", "'{:,s}'.format('s')", "'{:zs}'.format('s')",
    "'{:z}'.format(1)", "'{:,x}'.format(255)", "'{:_n}'.format(1)",
    "'{:.}'.format(1.0)", "'{:--5d}'.format(1)", "'{:5ff}'.format(1.0)",
    "'{:d}'.format(1.0)", "'{:+c}'.format(65)", "'{:#c}'.format(65)",
    "'{:c}'.format(-1)", "'{:c}'.format(1114112)",
    "'{:10}'.format(none)", "'{:10}'.format([1])",
    "'{:10}'.format(this)", "'{0[missing]:>3}'.format({})",
    "'{0.__class__.__mro__}'.format('s')",
    "'{0.__class__.__mro__[1].__subclasses__}'.format({})",
    "'{:05}'.format((-1)**0.5)", "'{:=10}'.format((-1)**0.5)",
    "'{:%}'.format((-1)**0.5)",
])
def test_native_string_format_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert native.returncode != 0
    assert not oracle.success


MAP_EXPRESSIONS = [
    "'{schema}.{identifier}'.format_map({'schema':'main','identifier':'orders'})",
    "'{x:{width}.{precision}f}'.format_map({'x':1.25,'width':8,'precision':2})",
    "'{x!r:>10}:{x!a}'.format_map({'x':'é'})",
    "'{x:#012_X}'.format_map({'x':11259375})",
    "'{x:🦆^7.2s}'.format_map({'x':'é好😀'})",
    "'{x:+z.2f}'.format_map({'x':-0.0001})",
    "'{x[a][1].real:.1f}'.format_map({'x':{'a':(0,2.5)}})",
    "'{x[01]}:{x[١]}'.format_map({'x':{1:'typed','1':'string'}})",
    "'{x[1]}'.format_map({'x':'é好😀'})",
    "'{x[missing]}:{x.missing}:{x[missing]!r}'.format_map({'x':{}})",
    "'{x.__class__}:{x[__class__]}'.format_map({'x':{'__class__':'data'}})",
    "'{x._private}'.format_map({'x':{'_private':'data'}})",
    "'{x.__globals__}:{x.__code__}'.format_map({'x':{'__globals__':'g','__code__':'c'}})",
    "'{x.__init__}:{x.__str__}:{x[__init__]}'.format_map({'x':{'__init__':'data','__str__':'data'}})",
    "'{x}:{y}'.format_map({'x':true,'y':none})",
    "'{x}'.format_map({'x':missing})",
    "'{identifier}'.format_map(this)",
    "'literal {{}}'.format_map({})",
    "'literal'.format_map(none)",
    "'literal'.format_map(1)",
    "'literal'.format_map(['unused'])",
    "'{x:{fill}<5}'.format_map({'x':'a','fill':'{'})",
]


@pytest.mark.parametrize('expression', MAP_EXPRESSIONS)
def test_native_string_format_map_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / 'project'
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize('expression', [
    "'literal'.format_map()", "'literal'.format_map({}, {})",
    "'literal'.format_map(mapping={})", "'literal'.format_map({}, x=1)",
    "'{missing}'.format_map({})", "'{0}'.format_map({'0':1})",
    "'{}'.format_map({'':1})", "'{x:{0}}'.format_map({'x':1})",
    "'{x:{width:{precision}}}'.format_map({'x':1,'width':2,'precision':3})",
    "'{x}'.format_map(none)", "'{x}'.format_map(1)",
    "'{x}'.format_map(['value'])", "'{x}'.format_map('value')",
    "'{x:d}'.format_map({'x':'value'})",
    "'{x[missing]:>3}'.format_map({'x':{}})",
    "'{x.__class__.__mro__}'.format_map({'x':'value'})",
])
def test_native_string_format_map_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / 'project'
    write_project(root, expression)
    common = ['compile', '--project-dir', str(root), '--profiles-dir', str(root), '--select', 'value']
    native = subprocess.run([DXT, *common], text=True, capture_output=True)
    oracle = core_runner.invoke(['--quiet', *common, '--no-partial-parse'])
    assert native.returncode != 0
    assert not oracle.success
