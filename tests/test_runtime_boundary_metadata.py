"""Safety scanner permits native language metadata and still rejects execution."""
from check_runtime_boundary import runtime_text


def test_python_language_metadata_is_not_an_interpreter_invocation():
    assert '"python"' not in runtime_text('if (std.mem.eql(u8, node.language, "python")) return;')
    assert '"python"' not in runtime_text('.language = "python",')
    assert '"python"' not in runtime_text('.language = if (std.mem.endsWith(u8, path, ".py")) "python" else "sql",')
    assert '"python"' in runtime_text('.argv = &.{ "python", "user-model.py" },')
    assert '"python3"' in runtime_text('.argv = &.{ "python3", "user-model.py" },')
    assert '"python"' in runtime_text('const interpreter = "python";')
