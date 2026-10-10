"""Standard Jinja filters compared with complete pinned Core compile output."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "'a/b é好?&=#%~' | urlencode", "'' | urlencode", "'a\\n\\t b' | urlencode",
    "123 | urlencode", "1.0 | urlencode", "none | urlencode", "true | urlencode",
    "((-1)**0.5) | urlencode", "fromyaml('.nan') | urlencode", "missing | urlencode",
    "{} | urlencode", "[] | urlencode", "{'a b':'é/好','x':'&=%~'} | urlencode",
    "{'x':[1,'a'],'y':(1,2),'z':none} | urlencode",
    "[(1,true),(false,1.0),(none,none)] | urlencode",
    "[('a','first'),('a','second')] | urlencode", "['ab','é好'] | urlencode",
    "zip(['a b','c'],[' /','é']) | urlencode",
    "[(fromyaml('!!binary Lw=='),fromyaml('!!binary /wA='))] | urlencode",
    "{fromyaml('2020-01-02'):'a b'} | urlencode",
    "fromyaml('2020-01-02') | urlencode",
    "'a b c' | wordwrap(3)", "'a b c' | wordwrap(width=3,wrapstring=' / ')",
    "'a b c' | wordwrap(3.0)", "'a b c' | wordwrap(10**400)",
    "'a b c' | wordwrap(fromyaml('.inf'))", "'abc' | wordwrap(true)",
    "'' | wordwrap(0)", "'' | wordwrap(none)", "'' | wordwrap('bad')",
    "'a\\n' | wordwrap(3)", "'a\\n\\n' | wordwrap(3)", "'\\n' | wordwrap(3)",
    "'a\\r\\nb\\rc\\x0bd\\x0ce\\x1cf\\x1dg\\x1eh' | wordwrap(2)",
    "'a\\u0085b\\u2028c\\u2029d' | wordwrap(2)",
    "'é好😀X' | wordwrap(3)", "'é好 😀 X' | wordwrap(3)",
    "'  a  b  c  ' | wordwrap(4)", "'a\\tb\\t c' | wordwrap(3)",
    "'a b c' | wordwrap(3)", "'  ' | wordwrap(2)",
    "'abcdefgh a' | wordwrap(3,break_long_words=false)",
    "'abcdefgh a' | wordwrap(3,break_long_words=true)",
    "'goof-ball -- use the -b option!' | wordwrap(6)",
    "'goof-ball -- use the -b option!' | wordwrap(6,break_on_hyphens=false)",
    "'goof-ball' | wordwrap(4)", "'goof-ball' | wordwrap(5,break_long_words=false)",
    "'éé-éé' | wordwrap(3)", "'aa-1-aa-bb' | wordwrap(4)",
    "'a--b aa---bb ----aaaa' | wordwrap(4)",
    "'goof-ball' | wordwrap(5,break_on_hyphens=1)",
    "'goof-ball' | wordwrap(5,break_on_hyphens='yes',break_long_words=false)",
    "'abc def' | wordwrap(3,break_long_words=none,wrapstring='')",
])
def test_standard_text_filters_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", [
    "'a' | urlencode(1)", "'a' | urlencode(unexpected=true)",
    "(1+2j) | urlencode",
    "[1] | urlencode", "['a'] | urlencode", "['abc'] | urlencode",
    "fromyaml('!!binary YQ==') | urlencode", "[(1,2,3)] | urlencode",
    "'abc' | wordwrap(0)", "'abc' | wordwrap(-1)", "'abc' | wordwrap(false)",
    "'abc' | wordwrap(none)", "'abc' | wordwrap('2')", "'abcd' | wordwrap(2.0)",
    "'a' | wordwrap(wrapstring=1)", "'' | wordwrap(wrapstring=1)",
    "1 | wordwrap", "none | wordwrap", "[] | wordwrap", "missing | wordwrap",
    "'a' | wordwrap(width=3,unexpected=true)", "'a' | wordwrap(3,width=4)",
    "'a' | wordwrap(1,true,'x',true,5)",
])
def test_standard_text_filter_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0, actual.stdout
    assert not oracle.success
