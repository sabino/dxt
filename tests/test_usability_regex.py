"""Native modules.re contracts against pinned dbt Core's Python re context."""
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import compare
from test_usability_expressions import write_project

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


EXPRESSIONS = [
    "modules.re.sub('[^\\\\w\\\\s-]', '', ' Héllo, Wörld! ') | lower | trim",
    "modules.re.search('a+', 'caaab').group()",
    "modules.re.match('a+', 'baa') is none",
    "modules.re.fullmatch('a+', 'aaa').span()",
    "modules.re.fullmatch('a+', 'aaab') is none",
    "modules.re.search('é', '好éx').span()",
    "modules.re.search('(?P<z>a)(?P<a>b)?', 'a').groupdict()",
    "modules.re.search('(a)(b)?', 'a').groups()",
    "modules.re.search('(a)(b)?', 'a').groups('missing')",
    "modules.re.search('(a)(b)?', 'a').group(0, 1, 2)",
    "modules.re.search('(a)(b)?', 'a')[1]",
    "modules.re.search('(?P<word>é)', '好é')['word']",
    "modules.re.search('(a)(b)?', 'a').span(2)",
    "modules.re.search('(a)(b)?', 'a').start(2)",
    "modules.re.search('(a)(b)?', 'a').end(2)",
    "modules.re.search('(a(b))', 'ab').lastindex",
    "modules.re.search('(?P<a>a)(?P<b>b)', 'ab').lastgroup",
    "modules.re.search('abc', 'abc')",
    "modules.re.compile('(?P<z>a)(?P<a>b)').groupindex",
    "modules.re.compile('a+', modules.re.I).pattern",
    "modules.re.compile('a+', modules.re.I).flags",
    "modules.re.compile('a+', modules.re.I).groups",
    "modules.re.compile('a+', modules.re.I)",
    "modules.re.compile('é+').search('好ééx',1,3).span()",
    "modules.re.compile('é+').search('好ééx',1,3).pos",
    "modules.re.compile('é+').search('好ééx',1,3).endpos",
    "modules.re.compile('^a').search('ba',1) is none",
    "modules.re.compile('a$').search('ba!',0,2).span()",
    "modules.re.compile('a').fullmatch('ab',0,1).group()",
    "modules.re.findall('a+', 'baa ca')",
    "modules.re.findall('(a)(b)?', 'a ab')",
    "modules.re.findall('(a)?b', 'b ab')",
    "modules.re.findall('.*?', 'ab')",
    "modules.re.sub('.*?', '-', 'ab')",
    "modules.re.sub('x*', '-', 'abxd')",
    "modules.re.subn('(a)', '<\\\\1>', 'aba')",
    "modules.re.sub('(?P<w>\\\\w+)', '<\\\\g<w>>', 'é 好')",
    "modules.re.sub('(a)?b', '[\\\\1]', 'b ab')",
    "modules.re.sub('a', 'X', 'aaa', count=2)",
    "modules.re.sub('a', 'X', 'aaa', count=-1)",
    "modules.re.compile('a').subn('X', 'aaa', 2)",
    "modules.re.search('(?P<a>a)', 'a').expand('<\\\\g<a>>-\\\\1')",
    "modules.re.split('(,)', 'a,b,c')",
    "modules.re.split('(?:,)', 'a,b,c',maxsplit=1)",
    "modules.re.split('', 'ab')",
    "modules.re.split('(a)?b', 'b ab')",
    "modules.re.split(',', 'a,b', maxsplit=-1)",
    "modules.re.escape('a_é .*+?[](){}^$#&~\\\\-\\t\\n')",
    "modules.re.I",
    "modules.re.NOFLAG",
    "modules.re.ASCII.value",
    "modules.re.I.name",
    "modules.re.I == 2 and modules.re.I is integer and modules.re.I is number",
    "modules.re.I + modules.re.M",
    "modules.re.I | tojson",
    "modules.re.findall('é', 'É é', modules.re.I)",
    "modules.re.findall('[a-z]', 'İıſKAb', modules.re.I)",
    "modules.re.findall('[a-z]', 'İıſKAb', modules.re.A + modules.re.I)",
    "modules.re.findall('\\\\w+', 'é好_²Ⅳ́‿')",
    "modules.re.findall('\\\\W+', 'é好_²Ⅳ́‿')",
    "modules.re.findall('[\\\\W_]+', 'é好_²Ⅳ́‿')",
    "modules.re.findall('[^\\\\W_]+', 'é好_²Ⅳ́‿')",
    "modules.re.findall('\\\\d+', '１２٣²')",
    "modules.re.findall('\\\\s+', 'a\\u001c\\u001d\\u001e\\u001f\\u00a0\\u2003b')",
    "modules.re.findall('\\\\b\\\\w+\\\\b', 'é́好‿x')",
    "modules.re.findall('\\\\B', '')",
    "modules.re.findall('\\\\B', 'a b')",
    "modules.re.search('a\\\\Z', 'a\\n') is none",
    "modules.re.findall('(?a:\\\\w+)|(?u:\\\\w+)', 'abc é好')",
    "modules.re.findall('(?m)^a', 'a\\na')",
    "modules.re.fullmatch('a.b', 'a\\nb', modules.re.S).group()",
    "modules.re.fullmatch('a # comment\\n b', 'ab', modules.re.X).group()",
    "modules.re.search('(?<=a)b(?=c)', 'abc').group()",
    "modules.re.search('(a)\\\\1', 'aa').group()",
    "modules.re.search('(?P<a>a)(?P=a)', 'aa').group()",
    "modules.re.search('(?>a*)a', 'aa') is none",
    "modules.re.fullmatch('a++a','aa') is none",
]


@pytest.mark.parametrize("expression", EXPRESSIONS)
def test_regular_expression_core_contract(tmp_path, core_runner, expression):
    root = tmp_path / "regex_contract"
    write_project(root, expression)
    compare(root, core_runner)


TEMPLATES = [
    "{% set p = modules.re.compile('(?P<a>a)') %}{{ modules.re.compile(p) is sameas(p) }}|{{ p.findall('aba') }}|{{ p.match('ab').groupdict() }}",
    "{% set matches = modules.re.finditer('a+', 'aa ba') %}{{ matches is iterable }}|{{ matches | map(attribute='lastindex') | list }}|{{ matches | list }}",
    "{% set matches = modules.re.finditer('a+', 'aa ba') %}{% for m in matches %}{{ m.span() }}:{{ m.group() }};{% endfor %}{{ matches | list }}",
    "{% macro replacement(m) %}{{ m.group(0)|upper }}{% endmacro %}{{ modules.re.sub('[a-z]+', replacement, 'abc de') }}",
    "{% macro replacement(m) %}{{ return(m.group(0)|upper) }}{% endmacro %}{{ modules.re.subn('[a-z]+', replacement, 'abc de') }}",
    "{% set p = modules.re.compile('a') %}{{ modules.re.search(p, 'ba').span() }}|{{ modules.re.findall(p,'aaa') }}",
    "{{ modules.re.purge() }}",
]


@pytest.mark.parametrize("template", TEMPLATES)
def test_bound_patterns_iterators_and_callable_replacements(tmp_path, core_runner, template):
    root = tmp_path / "regex_contract"
    write_project(root, "0")
    (root / "models/value.sql").write_text("select '" + template + "' as rendered\n")
    compare(root, core_runner)


@pytest.mark.parametrize("expression", [
    "modules.re.sub('[a-z]+', replacement, 'abc de')",
    "modules.re.subn('[a-z]+', replacement_native, 'abc de')",
])
def test_global_macro_replacements(tmp_path, core_runner, expression):
    root = tmp_path / "regex_contract"
    write_project(root, expression)
    (root / "macros").mkdir()
    (root / "macros/replacements.sql").write_text(
        "{% macro replacement(m) %}{{ m.group(0)|upper }}{% endmacro %}\n"
        "{% macro replacement_native(m) %}{{ return(m.group(0)|upper) }}{% endmacro %}\n"
    )
    compare(root, core_runner)


INVALID = [
    "modules.re.compile('[')",
    "modules.re.compile('(?P<bad>a)(?P<bad>b)')",
    "modules.re.compile('(?<=a+)b')",
    "modules.re.compile('(?<=a|bc)d')",
    "modules.re.compile('a', modules.re.L)",
    "modules.re.compile('a', modules.re.A + modules.re.U)",
    "modules.re.compile('a', 4.0)",
    "modules.re.compile('\\\\K')",
    "modules.re.compile('(?|a)')",
    "modules.re.compile('(?R)')",
    "modules.re.compile('a(?i)b')",
    "modules.re.search('a', 'a').group(2)",
    "modules.re.search('a', 'a').group('missing')",
    "modules.re.sub('(a)', '\\\\2', 'no match')",
    "modules.re.sub('(a)', '\\\\q', 'no match')",
    "modules.re.search('a', 'a').expand('\\\\g<missing>')",
    "modules.re.compile(modules.re.compile('a'), modules.re.I)",
    "modules.re.search('a', 42)",
    "modules.re.finditer('a','aa') | length",
]


@pytest.mark.parametrize("expression", INVALID)
def test_invalid_regex_matches_core_failure(tmp_path, core_runner, expression):
    root = tmp_path / "regex_invalid"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--no-partial-parse"]
    native = subprocess.run([str(DXT), *common, "--target-path", "native"], cwd=ROOT, capture_output=True, text=True)
    core = core_runner.invoke(["--quiet", *common, "--target-path", "core"])
    assert native.returncode != 0, native.stdout + native.stderr
    assert not core.success, core.result
