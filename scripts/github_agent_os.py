from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from check_agent_os_config import LABELS_PATH, PROJECT_PATH, SEED_ISSUES_PATH, load_json, validate_config


ROOT = Path(__file__).resolve().parents[1]


def gh(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["CLICOLOR"] = "0"
    env["CLICOLOR_FORCE"] = "0"
    env["GH_FORCE_TTY"] = "0"
    env["TERM"] = "dumb"
    env.pop("FORCE_COLOR", None)
    return subprocess.run(
        ["gh", *args],
        cwd=ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )


def default_repo() -> str:
    result = gh(["repo", "view", "--json", "nameWithOwner"], check=False)
    if result.returncode != 0:
        return "sabino/dxt"
    return json.loads(result.stdout)["nameWithOwner"]


def project_repo_name(owner: str, repo: str) -> str:
    if "/" not in repo:
        return repo
    repo_owner, repo_name = repo.split("/", 1)
    if repo_owner != owner:
        raise ValueError(f"--repo {repo!r} does not belong to --owner {owner!r}")
    return repo_name


def labels(args: argparse.Namespace) -> int:
    configured = load_json(LABELS_PATH)
    assert isinstance(configured, list)
    repo = args.repo or default_repo()

    if args.dry_run:
        print(f"would sync {len(configured)} labels for {repo}")
        for label in configured:
            print(f"  {label['name']} #{label['color']} - {label['description']}")
        return 0

    remote_result = gh(["label", "list", "--repo", repo, "--limit", "1000", "--json", "name,color,description"], check=False)
    if remote_result.returncode != 0:
        print(remote_result.stderr, file=sys.stderr)
        return remote_result.returncode
    remote = {label["name"]: label for label in json.loads(remote_result.stdout)}

    drift = False
    for label in configured:
        name = label["name"]
        color = label["color"]
        description = label["description"]
        current = remote.get(name)
        if current is None:
            drift = True
            if args.check:
                print(f"missing label: {name}")
            else:
                print(f"creating label: {name}")
                gh(["label", "create", name, "--repo", repo, "--color", color, "--description", description])
            continue
        current_color = str(current.get("color", "")).lower().lstrip("#")
        current_description = current.get("description") or ""
        if current_color != color.lower() or current_description != description:
            drift = True
            if args.check:
                print(f"label drift: {name}")
            else:
                print(f"updating label: {name}")
                gh(["label", "edit", name, "--repo", repo, "--color", color, "--description", description])

    if args.check and drift:
        return 1
    if args.check:
        print("GitHub labels match manifest.")
    return 0


def seed_issues(args: argparse.Namespace) -> int:
    issues = load_json(SEED_ISSUES_PATH)
    assert isinstance(issues, list)
    repo = args.repo or default_repo()

    if args.dry_run:
        print(f"would create missing seed issues for {repo}")
        for issue in issues:
            print(f"  {issue['title']} [{', '.join(issue['labels'])}]")
        return 0

    existing_result = gh(["issue", "list", "--repo", repo, "--state", "all", "--limit", "1000", "--json", "number,title,url"], check=False)
    if existing_result.returncode != 0:
        print(existing_result.stderr, file=sys.stderr)
        return existing_result.returncode
    existing = {issue["title"]: issue for issue in json.loads(existing_result.stdout)}

    for issue in issues:
        if issue["title"] in existing:
            print(f"exists: #{existing[issue['title']]['number']} {issue['title']}")
            continue
        cmd = ["issue", "create", "--repo", repo, "--title", issue["title"]]
        for label in issue["labels"]:
            cmd.extend(["--label", label])
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(issue["body"])
            handle.write("\n")
            body_path = handle.name
        try:
            print(f"creating issue: {issue['title']}")
            gh([*cmd, "--body-file", body_path])
        finally:
            Path(body_path).unlink(missing_ok=True)
    return 0


def project(args: argparse.Namespace) -> int:
    manifest = load_json(PROJECT_PATH)
    assert isinstance(manifest, dict)
    owner = args.owner
    repo = args.repo or default_repo()
    try:
        project_repo = project_repo_name(owner, repo)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.dry_run:
        print(f"would ensure project {manifest['title']!r} for owner {owner}")
        print(f"would link repository {project_repo}")
        for field in manifest["fields"]:
            if field["type"] == "SINGLE_SELECT":
                print(f"  field {field['name']} ({field['type']}): {', '.join(field['options'])}")
            else:
                print(f"  field {field['name']} ({field['type']})")
        return 0

    list_result = gh(["project", "list", "--owner", owner, "--format", "json"], check=False)
    if list_result.returncode != 0:
        print(list_result.stderr, file=sys.stderr)
        print("GitHub Projects bootstrap requires: gh auth refresh -s read:project -s project", file=sys.stderr)
        return list_result.returncode

    projects = json.loads(list_result.stdout).get("projects", [])
    found = next((item for item in projects if item.get("title") == manifest["title"]), None)
    if found is None:
        created = gh(["project", "create", "--owner", owner, "--title", manifest["title"], "--format", "json"])
        found = json.loads(created.stdout)
        print(f"created project: {manifest['title']}")
    number = str(found.get("number"))

    gh(["project", "link", number, "--owner", owner, "--repo", project_repo], check=False)
    field_result = gh(["project", "field-list", number, "--owner", owner, "--format", "json"])
    existing_fields = {field["name"] for field in json.loads(field_result.stdout).get("fields", [])}
    for field in manifest["fields"]:
        if field["name"] in existing_fields:
            print(f"field exists: {field['name']}")
            continue
        cmd = [
            "project",
            "field-create",
            number,
            "--owner",
            owner,
            "--name",
            field["name"],
            "--data-type",
            field["type"],
        ]
        if field["type"] == "SINGLE_SELECT":
            cmd.extend(["--single-select-options", ",".join(field["options"])])
        print(f"creating field: {field['name']}")
        gh(cmd)
    return 0


def validate(_: argparse.Namespace) -> int:
    findings = validate_config()
    if findings:
        print("Agent OS config check failed:")
        print("\n".join(findings))
        return 1
    print("Agent OS config check passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage dxt GitHub-backed agent coordination scaffolding.")
    sub = parser.add_subparsers(dest="command", required=True)

    validate_parser = sub.add_parser("validate")
    validate_parser.set_defaults(func=validate)

    label_parser = sub.add_parser("labels")
    label_mode = label_parser.add_mutually_exclusive_group(required=True)
    label_mode.add_argument("--dry-run", action="store_true")
    label_mode.add_argument("--check", action="store_true")
    label_mode.add_argument("--apply", action="store_true")
    label_parser.add_argument("--repo")
    label_parser.set_defaults(func=labels)

    issue_parser = sub.add_parser("seed-issues")
    issue_mode = issue_parser.add_mutually_exclusive_group(required=True)
    issue_mode.add_argument("--dry-run", action="store_true")
    issue_mode.add_argument("--apply", action="store_true")
    issue_parser.add_argument("--repo")
    issue_parser.set_defaults(func=seed_issues)

    project_parser = sub.add_parser("project")
    project_mode = project_parser.add_mutually_exclusive_group(required=True)
    project_mode.add_argument("--dry-run", action="store_true")
    project_mode.add_argument("--apply", action="store_true")
    project_parser.add_argument("--owner", default="sabino")
    project_parser.add_argument("--repo")
    project_parser.set_defaults(func=project)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
