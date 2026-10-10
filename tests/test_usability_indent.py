"""Jinja indentation executes through the native compiler and pinned Core."""
from __future__ import annotations

import pytest

from test_usability_commands import core_runner
from test_usability_expressions import native_binary
import test_usability_expressions as expressions


@pytest.mark.parametrize("expression", [
    "'first\\nsecond' | indent",
    "'first\\n\\nsecond\\n' | indent(2)",
    "'first\\n\\nsecond\\n' | indent(2,true,true)",
    "'first\\n\\nsecond\\n' | indent(blank=true,width='> ',first=true)",
    "'first\\nsecond' | indent(width='>\\n',first=true)",
    "'' | indent(2,first=true,blank=true)",
    "'a\\r\\nb\\rc\\n' | indent(first=true)",
    "'a\u0085b\u2028c\u2029d' | indent(2,true)",
    "'first\\nsecond' | indent(-3,first=true)",
    "'first\\nsecond' | indent(true)",
    "'first\\nsecond' | indent(false)",
    "'first\\n\\nsecond' | indent(blank=true)",
])
def test_indent_matches_pinned_core(tmp_path, core_runner, expression):
    expressions.test_native_expression_matches_core(tmp_path, core_runner, expression)


@pytest.mark.parametrize("expression", [
    "'text' | indent(width=none)",
    "'text' | indent(2.5)",
    "'text' | indent(indentfirst=true)",
    "'text' | indent(2,width=3)",
    "'text' | indent(2,false,false,false)",
    "3 | indent",
])
def test_invalid_indent_matches_pinned_core(tmp_path, core_runner, expression):
    expressions.test_invalid_collection_expression_fails_like_core(tmp_path, core_runner, expression)
