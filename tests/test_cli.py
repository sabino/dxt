from __future__ import annotations

from dxt import __version__
from dxt.cli import main


def test_version_command(capsys):
    assert main(["version"]) == 0
    assert capsys.readouterr().out.strip() == __version__


def test_planned_command_returns_nonzero(capsys):
    assert main(["parse", "--project-dir", "fixture", "--select", "tag:nightly"]) == 2
    output = capsys.readouterr().out
    assert "planned but not implemented" in output
    assert "PLAN.md" in output


def test_docs_generate_placeholder(capsys):
    assert main(["docs", "generate", "--target-path", "target-dxt"]) == 2
    output = capsys.readouterr().out
    assert "dxt docs generate" in output
