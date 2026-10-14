"""PR-only release qualification and fail-closed workflow boundary coverage."""
from __future__ import annotations

import importlib
import json
from pathlib import Path
import subprocess

import pytest
import yaml


@pytest.fixture
def release(monkeypatch):
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[1] / "scripts"))
    return importlib.import_module("release_workflow")


@pytest.fixture
def evidence(release):
    run = {"id": 100, "head_sha": "a" * 40, "event": "pull_request", "status": "completed", "conclusion": "success"}
    record = {"schema_version": 1, "repository": "owner/repo", "run_id": 100, "event": "pull_request",
              "head_sha": "a" * 40, "source_commit": "b" * 40, "source_tree": "c" * 40,
              "targets": sorted(release.RELEASE_TARGETS)}
    return run, record


def test_certificate_accepts_squash_merge_with_same_tested_tree(release, evidence):
    run, record = evidence
    release.validate_certificate(record, repository="owner/repo", run=run, tree="c" * 40)
    assert record["source_commit"] != run["head_sha"]


@pytest.mark.parametrize("key,value", [("schema_version", 0), ("repository", "other/repo"), ("run_id", 101),
    ("event", "push"), ("head_sha", "d" * 40), ("source_tree", "d" * 40),
    ("source_commit", "branch-name"), ("targets", ["aarch64-macos"])])
def test_wrong_source_or_incomplete_platform_evidence_rejects_publication(release, evidence, key, value):
    run, record = evidence
    record[key] = value
    with pytest.raises(ValueError, match="does not certify"):
        release.validate_certificate(record, repository="owner/repo", run=run, tree="c" * 40)


@pytest.mark.parametrize("key,value", [("event", "push"), ("status", "in_progress"), ("conclusion", "failure"), ("conclusion", "cancelled")])
def test_unsuccessful_or_non_pr_runs_cannot_qualify(release, evidence, key, value):
    run, record = evidence
    run[key] = value
    with pytest.raises(ValueError, match="completed, successful"):
        release.validate_certificate(record, repository="owner/repo", run=run, tree="c" * 40)


@pytest.mark.parametrize("result", ["failure", "cancelled", "skipped", "timed_out"])
def test_partial_ci_cannot_issue_a_source_certificate(release, result):
    with pytest.raises(ValueError, match="every required CI job"):
        release.certificate({"core": {"result": "success"}, "macos": {"result": result}}, {})


@pytest.mark.parametrize("expired,merged", [(True, True), (False, False)])
def test_expired_or_unmerged_evidence_cannot_qualify(release, evidence, monkeypatch, expired, merged):
    run, _ = evidence
    def api(endpoint):
        if "/commits/" in endpoint:
            return [{"merged_at": "date" if merged else None, "head": {"sha": run["head_sha"]}}]
        if "/workflows/" in endpoint:
            return {"workflow_runs": [run]}
        return {"artifacts": [{"name": "validated-source", "expired": expired}]}
    monkeypatch.setattr(release, "gh_json", api)
    monkeypatch.setattr(release.subprocess, "run", lambda *a, **kw: pytest.fail("unqualified artifact downloaded"))
    with pytest.raises(ValueError, match="no successful merged PR"):
        release.qualify("owner/repo", "b" * 40, "c" * 40)


def test_qualification_reads_and_matches_actual_run_certificate(release, evidence, monkeypatch):
    run, record = evidence
    def api(endpoint):
        if "/commits/" in endpoint:
            return [{"merged_at": "date", "head": {"sha": run["head_sha"]}}]
        if "/workflows/" in endpoint:
            return {"workflow_runs": [run]}
        return {"artifacts": [{"name": "validated-source", "expired": False}]}
    def download(arguments, **kwargs):
        directory = Path(arguments[arguments.index("--dir") + 1])
        (directory / "validated-source.json").write_text(json.dumps(record))
    monkeypatch.setattr(release, "gh_json", api)
    monkeypatch.setattr(release.subprocess, "run", download)
    assert release.qualify("owner/repo", "d" * 40, "c" * 40) == record
    with pytest.raises(ValueError, match="no successful merged PR"):
        release.qualify("owner/repo", "d" * 40, "e" * 40)


@pytest.mark.parametrize("tag,version", [("v0.0.0", "0.0.0"), ("v0.1.0-alpha.1", "0.1.0-alpha.1")])
def test_version_resolution_uses_the_tagged_commit_not_dispatch_checkout(release, tmp_path, monkeypatch, tag, version):
    root = tmp_path / "repository"
    root.mkdir()
    monkeypatch.setattr(release, "ROOT", root)
    def git(*arguments):
        return subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
                               "-c", "user.name=Release Tests", "-c", "user.email=release@example.invalid",
                               *arguments], cwd=root, check=True, capture_output=True, text=True)
    git("init", "-q")
    metadata = root / "build.zig.zon"
    metadata.write_text(f'.{{ .version = "{version}" }}')
    git("add", ".")
    git("commit", "-qm", "Tagged source")
    git("tag", tag)
    expected = git("rev-parse", "HEAD").stdout.strip()
    metadata.write_text('.{ .version = "9.9.9" }')
    git("commit", "-qam", "Different dispatch checkout")
    assert release.source(tag)[0] == expected
    with pytest.raises(ValueError, match="must match build.zig.zon"):
        git("tag", "v2.0.0")
        release.source("v2.0.0")


@pytest.mark.parametrize("tag", ["main", "v1.2", "v1.2.3/path", "v1.2.3\nrevision=evil", "v1.2.3;$()"])
def test_invalid_tag_is_rejected_before_git_or_output(release, monkeypatch, tag):
    monkeypatch.setattr(release, "git", lambda *a: pytest.fail("unsafe tag reached git"))
    with pytest.raises(ValueError, match="release tag"):
        release.source(tag)


def workflow(name):
    path = Path(__file__).resolve().parents[1] / ".github/workflows" / name
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def test_full_tests_are_pr_only_and_certificate_requires_every_ci_job():
    ci = workflow("ci.yml")
    assert set(ci["on"]) == {"pull_request"}
    assert "push" not in workflow("coverage.yml")["on"]
    assert set(ci["jobs"]["validated-source"]["needs"]) == set(ci["jobs"]) - {"validated-source"}


def test_tag_and_ui_releases_automatically_publish_after_all_packages_pass():
    release = workflow("release.yml")
    assert release["on"]["push"]["tags"] == ["v*.*.*"]
    assert release["on"]["release"]["types"] == ["published"]
    assert release["on"]["workflow_dispatch"]["inputs"]["dry_run"]["default"] == "true"
    assert set(release["jobs"]["publish"]["needs"]) == {"qualify", "linux", "macos"}
    assert release["jobs"]["macos"]["with"]["native_tests"] == "false"
    publish = "\n".join(step.get("run", "") for step in release["jobs"]["publish"]["steps"])
    assert "--require-all-targets" in publish
    assert "--draft \\" not in publish
    assert "--prerelease" in publish
    assert "release_workflow.py check-tag" in publish
