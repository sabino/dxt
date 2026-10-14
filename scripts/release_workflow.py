"""Developer-only release qualification against complete PR CI evidence."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from check_release_archive import RELEASE_TARGETS, VERSION_RE

ROOT = Path(__file__).resolve().parents[1]
SHA_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True).strip()


def source(tag):
    if not tag.startswith("v") or not VERSION_RE.fullmatch(tag[1:]):
        raise ValueError("release tag must look like v0.1.0 or v0.1.0-alpha.1")
    revision = git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    tree = git("rev-parse", f"{revision}^{{tree}}")
    metadata = git("show", f"{revision}:build.zig.zon")
    version = re.search(r'\.version\s*=\s*"([^"\n]+)"', metadata)
    if version is None or version[1] != tag[1:]:
        raise ValueError("release tag version must match build.zig.zon at the tagged commit")
    return revision, tree


def certificate(needs, environment):
    if not needs or any(job.get("result") != "success" for job in needs.values()):
        raise ValueError("every required CI job must succeed before certifying its source")
    if environment.get("GITHUB_EVENT_NAME") != "pull_request":
        raise ValueError("source certification requires a pull-request CI run")
    record = {
        "schema_version": 1,
        "repository": environment["GITHUB_REPOSITORY"],
        "run_id": int(environment["GITHUB_RUN_ID"]),
        "event": "pull_request",
        "head_sha": environment["PR_HEAD_SHA"],
        "source_commit": git("rev-parse", "HEAD"),
        "source_tree": git("rev-parse", "HEAD^{tree}"),
        "targets": sorted(RELEASE_TARGETS),
    }
    if any(not SHA_RE.fullmatch(record[key]) for key in ("head_sha", "source_commit", "source_tree")):
        raise ValueError("CI source identities must be full immutable git hashes")
    return record


def validate_certificate(record, *, repository, run, tree):
    if not isinstance(record, dict):
        raise ValueError("PR validation record does not certify this release source and target set")
    if (record.get("schema_version") != 1 or record.get("repository") != repository
            or record.get("event") != "pull_request" or record.get("run_id") != run["id"]
            or record.get("head_sha") != run["head_sha"]
            or record.get("source_tree") != tree
            or record.get("targets") != sorted(RELEASE_TARGETS)
            or not isinstance(record.get("source_commit"), str)
            or not SHA_RE.fullmatch(record["source_commit"])):
        raise ValueError("PR validation record does not certify this release source and target set")
    if run.get("event") != "pull_request" or run.get("conclusion") != "success" or run.get("status") != "completed":
        raise ValueError("release source requires a completed, successful pull-request CI run")


def gh_json(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))


def qualify(repository, revision, tree):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("invalid GitHub repository name")
    pulls = gh_json(f"repos/{repository}/commits/{revision}/pulls?per_page=100")
    for pull in pulls:
        if not pull.get("merged_at"):
            continue
        head = pull["head"]["sha"]
        if not SHA_RE.fullmatch(head):
            raise ValueError("invalid associated PR source hash")
        runs = gh_json(f"repos/{repository}/actions/workflows/ci.yml/runs"
                       f"?event=pull_request&status=success&head_sha={head}&per_page=100")
        for run in runs["workflow_runs"]:
            if run["head_sha"] != head:
                continue
            artifacts = gh_json(f"repos/{repository}/actions/runs/{run['id']}/artifacts?per_page=100")
            if not any(item["name"] == "validated-source" and not item["expired"]
                       for item in artifacts["artifacts"]):
                continue
            with tempfile.TemporaryDirectory(prefix="dxt-ci-evidence-") as temporary:
                subprocess.run(["gh", "run", "download", str(run["id"]), "--repo", repository,
                                "--name", "validated-source", "--dir", temporary], check=True)
                record = json.loads((Path(temporary) / "validated-source.json").read_text())
            try:
                validate_certificate(record, repository=repository, run=run, tree=tree)
            except ValueError:
                continue
            return record
    raise ValueError("no successful merged PR certifies this exact release tree and all targets; "
                     "merge a fully validated release-preparation PR (or rerun its expired CI)")


def write_record(path, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    certify = commands.add_parser("certify")
    certify.add_argument("--output", type=Path, required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--tag", required=True)
    prepare.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    prepare.add_argument("--github-output", type=Path, required=True)
    prepare.add_argument("--record-dir", type=Path, required=True)
    check_tag = commands.add_parser("check-tag")
    check_tag.add_argument("--tag", required=True)
    check_tag.add_argument("--revision", required=True)
    args = parser.parse_args(argv)
    if args.command == "certify":
        write_record(args.output, certificate(json.loads(os.environ["CI_JOB_RESULTS"]), os.environ))
    elif args.command == "prepare":
        revision, tree = source(args.tag)
        record = qualify(args.repository, revision, tree)
        record.update(release_tag=args.tag, release_commit=revision)
        write_record(args.record_dir / f"dxt-{args.tag}-validation.json", record)
        prerelease = "true" if "-" in args.tag or args.tag == "v0.0.0" else "false"
        with args.github_output.open("a") as output:
            output.write(f"tag={args.tag}\nversion={args.tag[1:]}\nrevision={revision}\nprerelease={prerelease}\n")
    else:
        # Fetch only the requested tag again before publication, then reject a
        # tag moved after qualification. Builds always use the resolved commit.
        if not args.tag.startswith("v") or not VERSION_RE.fullmatch(args.tag[1:]):
            raise ValueError("invalid release tag")
        subprocess.run(["git", "fetch", "--force", "origin",
                        f"refs/tags/{args.tag}:refs/tags/{args.tag}"], cwd=ROOT, check=True)
        if source(args.tag)[0] != args.revision:
            raise ValueError("release tag moved after its source was qualified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
