from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from check_agent_os_config import LABELS_PATH, PROJECT_PATH, SEED_ISSUES_PATH, load_json, validate_config


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCY_PATTERNS = (
    re.compile(r"\bdepends_on=#(\d+)\b", re.IGNORECASE),
    re.compile(r"\bdepends(?:\s+on)?\s*[:=]\s*#(\d+)\b", re.IGNORECASE),
    re.compile(r"\bblocked(?:\s+by)?\s*[:=]\s*#(\d+)\b", re.IGNORECASE),
)
AGENT_EVENT_PATTERN = re.compile(r"<!--\s*dxt-agent-event:v1\s+(.*?)-->", re.IGNORECASE | re.DOTALL)
AGENT_EVENT_ATTR_PATTERN = re.compile(r"([A-Za-z_][A-Za-z0-9_-]*)=([^\s>]+)")
LOCAL_PATH_PATTERNS = (
    re.compile("/home/" + "sabino"),
    re.compile("/media/" + "sabino"),
    re.compile("SABINO" + "_EXT4"),
)


def gh(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["gh", *args],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=no_color_env(),
    )
    if check and result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
    return result


def gh_graphql(query: str, variables: dict[str, object], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["gh", "api", "graphql", "--input", "-"],
        cwd=ROOT,
        check=False,
        text=True,
        input=json.dumps({"query": query, "variables": variables}),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=no_color_env(),
    )
    if check and result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
    return result


def no_color_env() -> dict[str, str]:
    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["CLICOLOR"] = "0"
    env["CLICOLOR_FORCE"] = "0"
    env["GH_FORCE_TTY"] = "0"
    env["TERM"] = "dumb"
    env.pop("FORCE_COLOR", None)
    return env


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


def project_owner_repo(repo: str, *, expected_owner: str | None = None) -> tuple[str, str]:
    if "/" not in repo:
        raise ValueError("--repo must use OWNER/REPO for Project item sync")
    owner, name = repo.split("/", 1)
    if expected_owner is not None and owner != expected_owner:
        raise ValueError(f"--repo {repo!r} does not belong to --owner {expected_owner!r}")
    return owner, name


def project_number_and_id(owner: str, title: str) -> tuple[str, str] | None:
    list_result = gh(["project", "list", "--owner", owner, "--format", "json"], check=False)
    if list_result.returncode != 0:
        print(list_result.stderr, file=sys.stderr)
        return None
    projects = json.loads(list_result.stdout).get("projects", [])
    found = next((item for item in projects if item.get("title") == title), None)
    if found is None:
        return None
    return str(found["number"]), str(found["id"])


def single_select_field_details(field_id: str) -> dict[str, object]:
    query = """
    query($id: ID!) {
      node(id: $id) {
        ... on ProjectV2SingleSelectField {
          id
          name
          options {
            id
            name
            color
            description
          }
        }
      }
    }
    """
    result = gh_graphql(query, {"id": field_id})
    payload = json.loads(result.stdout)
    if payload.get("errors"):
        raise RuntimeError(json.dumps(payload["errors"], indent=2))
    node = payload.get("data", {}).get("node")
    if not isinstance(node, dict):
        raise RuntimeError(f"Project field is not a single-select field: {field_id}")
    return node


def update_single_select_options(field_id: str, options: list[dict[str, str]]) -> None:
    query = """
    mutation($fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]) {
      updateProjectV2Field(input: {fieldId: $fieldId, singleSelectOptions: $options}) {
        projectV2Field {
          ... on ProjectV2SingleSelectField {
            id
            name
          }
        }
      }
    }
    """
    result = gh_graphql(query, {"fieldId": field_id, "options": options})
    payload = json.loads(result.stdout)
    if payload.get("errors"):
        raise RuntimeError(json.dumps(payload["errors"], indent=2))


def reconcile_single_select_options(field: dict[str, object], desired_names: list[str]) -> bool:
    details = single_select_field_details(str(field["id"]))
    current_options = details.get("options") or []
    if not isinstance(current_options, list):
        raise RuntimeError(f"Project field options are unavailable: {field.get('name')}")
    current_by_name = {
        option["name"]: option
        for option in current_options
        if isinstance(option, dict) and isinstance(option.get("name"), str)
    }
    missing = [name for name in desired_names if name not in current_by_name]
    if not missing:
        return False

    merged: list[dict[str, str]] = []
    for option in current_options:
        if not isinstance(option, dict):
            continue
        name = option.get("name")
        if not isinstance(name, str):
            continue
        merged.append(
            {
                "id": str(option.get("id", "")),
                "name": name,
                "color": str(option.get("color") or "GRAY"),
                "description": str(option.get("description") or ""),
            }
        )
    for name in missing:
        merged.append({"name": name, "color": "GRAY", "description": ""})
    update_single_select_options(str(field["id"]), merged)
    return True


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
        print("GitHub Projects listing requires: gh auth refresh -s read:project", file=sys.stderr)
        print("GitHub Projects creation/field updates require: gh auth refresh -s project", file=sys.stderr)
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
    existing_fields = {
        field["name"]: field
        for field in json.loads(field_result.stdout).get("fields", [])
        if isinstance(field.get("name"), str)
    }
    for field in manifest["fields"]:
        current = existing_fields.get(field["name"])
        if current is not None:
            if field["type"] == "SINGLE_SELECT":
                if current.get("type") != "ProjectV2SingleSelectField":
                    print(f"field type mismatch: {field['name']} is {current.get('type')}", file=sys.stderr)
                    return 1
                if reconcile_single_select_options(current, field["options"]):
                    print(f"updated field options: {field['name']}")
                else:
                    print(f"field exists: {field['name']}")
                continue
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


def project_items(args: argparse.Namespace) -> int:
    manifest = load_json(PROJECT_PATH)
    assert isinstance(manifest, dict)
    repo = args.repo or default_repo()
    owner = args.owner
    try:
        project_owner_repo(repo, expected_owner=owner)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    project_ref = project_number_and_id(owner, manifest["title"])
    if project_ref is None:
        print(f"Project not found: {manifest['title']!r}; run project --apply first", file=sys.stderr)
        return 1
    number, project_id = project_ref

    issue_result = gh(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--limit",
            str(args.limit),
            "--json",
            "number,title,url,labels,body,comments",
        ],
        check=False,
    )
    if issue_result.returncode != 0:
        print(issue_result.stderr, file=sys.stderr)
        return issue_result.returncode
    issues = json.loads(issue_result.stdout)

    project_item_limit = max(int(getattr(args, "project_item_limit", 1000)), args.limit, 100)
    item_result = gh(
        [
            "project",
            "item-list",
            number,
            "--owner",
            owner,
            "--format",
            "json",
            "--limit",
            str(project_item_limit),
            "--query",
            f"repo:{repo} is:issue",
        ],
        check=False,
    )
    if item_result.returncode != 0:
        print(item_result.stderr, file=sys.stderr)
        return item_result.returncode
    existing_items = json.loads(item_result.stdout).get("items", [])
    existing_by_url = {
        (item.get("content") or {}).get("url"): item
        for item in existing_items
        if isinstance(item.get("content"), dict)
    }

    field_result = gh(["project", "field-list", number, "--owner", owner, "--format", "json"], check=False)
    if field_result.returncode != 0:
        print(field_result.stderr, file=sys.stderr)
        return field_result.returncode
    fields = json.loads(field_result.stdout).get("fields", [])
    project_fields = {
        field["name"]: {
            "id": field["id"],
            "type": field.get("type"),
            "options": {option["name"]: option["id"] for option in field.get("options", [])},
        }
        for field in fields
        if "id" in field and "name" in field
    }

    for issue in issues:
        labels_for_issue = {label["name"] for label in issue.get("labels", []) if isinstance(label, dict)}
        if not labels_for_issue.intersection({"ready-for-agent", "needs-reference-map", "needs-slice-plan", "status:ready", "status:claimed", "status:blocked", "status:review", "status:ci"}):
            continue
        item = existing_by_url.get(issue["url"])
        if item is None:
            if args.dry_run:
                print(f"would add issue #{issue['number']} to project")
                report_project_field_drift(project_id, None, project_fields, issue, dry_run=True)
                continue
            print(f"adding issue #{issue['number']} to project")
            added = gh(["project", "item-add", number, "--owner", owner, "--url", issue["url"], "--format", "json"])
            item = json.loads(added.stdout)
        else:
            print(f"exists in project: #{issue['number']}")
        if not report_project_field_drift(project_id, item, project_fields, issue, dry_run=args.dry_run):
            return 1
    return 0


def report_project_field_drift(
    project_id: str,
    item: dict[str, object] | None,
    fields: dict[str, dict[str, object]],
    issue: dict[str, object],
    *,
    dry_run: bool,
) -> bool:
    item_id = str(item["id"]) if item is not None and "id" in item else ""
    values, warnings = desired_project_values(issue)
    issue_number = issue.get("number", "?")
    for warning in warnings:
        print(f"project field skipped for issue #{issue_number}: {warning}")

    drift_found = False
    for field_name, option_name in values.items():
        if option_name is None:
            continue
        field = fields.get(field_name)
        if not field:
            message = f"missing project field: {field_name}"
            if dry_run:
                print(f"would need field for issue #{issue_number}: {field_name}")
                drift_found = True
                continue
            print(message, file=sys.stderr)
            return False

        desired = str(option_name)
        current = project_item_field_value(item or {}, field_name)
        if current == desired:
            continue

        drift_found = True
        current_display = current if current else "<empty>"
        desired_display = desired if desired else "<empty>"
        if dry_run:
            print(f"field drift issue #{issue_number}: {field_name}: {current_display} -> {desired_display}")
            continue

        if not set_project_field(project_id, item_id, field_name, field, desired):
            return False
        print(f"updated issue #{issue_number}: {field_name} -> {desired_display}")

    if dry_run and item is not None and not drift_found:
        print(f"project fields match: issue #{issue_number}")
    return True


def set_project_field(
    project_id: str,
    item_id: str,
    field_name: str,
    field: dict[str, object],
    desired: str,
) -> bool:
    field_type = field.get("type")
    if field_type == "ProjectV2SingleSelectField":
        options = field.get("options")
        if not isinstance(options, dict):
            print(f"project field options are invalid: {field_name}", file=sys.stderr)
            return False
        option_id = options.get(desired)
        if not option_id:
            print(f"missing project option: {field_name}={desired}", file=sys.stderr)
            return False
        gh(
            [
                "project",
                "item-edit",
                "--id",
                item_id,
                "--project-id",
                project_id,
                "--field-id",
                str(field["id"]),
                "--single-select-option-id",
                str(option_id),
            ]
        )
        return True

    if field_type == "ProjectV2Field":
        cmd = [
            "project",
            "item-edit",
            "--id",
            item_id,
            "--project-id",
            project_id,
            "--field-id",
            str(field["id"]),
        ]
        if desired:
            cmd.extend(["--text", desired])
        else:
            cmd.append("--clear")
        gh(cmd)
        return True

    print(f"unsupported project field type for {field_name}: {field_type}", file=sys.stderr)
    return False


def desired_project_values(issue: dict[str, object]) -> tuple[dict[str, str | None], list[str]]:
    labels_for_issue = label_names(issue.get("labels"))
    events = issue_event_attributes(issue)
    warnings: list[str] = []
    values = {
        "Agent Status": status_value(labels_for_issue, latest_event_value(events, "status")),
        "Agent Role": role_value(labels_for_issue, latest_event_value(events, "role"), warnings),
        "Track": track_value(labels_for_issue),
        "Pattern": pattern_value(labels_for_issue),
        "Validation": validation_value(labels_for_issue),
        "Source Grounding": source_grounding_value(labels_for_issue),
        "PLAN Update": plan_update_value(labels_for_issue),
        "Readiness": readiness_value(labels_for_issue, latest_event_value(events, "status")),
        "Branch": branch_value(events, warnings),
        "Dependencies": dependency_value(issue),
    }
    return values, warnings


def label_names(value: object) -> set[str]:
    if not isinstance(value, list):
        return set()
    names: set[str] = set()
    for item in value:
        if isinstance(item, str):
            names.add(item)
        elif isinstance(item, dict) and isinstance(item.get("name"), str):
            names.add(item["name"])
    return names


def status_value(labels_for_issue: set[str], event_status: str | None = None) -> str:
    event_map = {
        "blocked": "Blocked",
        "unblocked": "Ready",
        "ready": "Ready",
        "claimed": "Claimed",
        "in_worktree": "In Worktree",
        "in-worktree": "In Worktree",
        "validated": "Local Validation",
        "ci": "CI Running",
        "ci-red": "CI Red",
        "review": "Needs Review",
        "merged": "Merged",
    }
    if event_status in event_map:
        return event_map[event_status]
    if "status:blocked" in labels_for_issue:
        return "Blocked"
    if "status:review" in labels_for_issue:
        return "Needs Review"
    if "status:ci" in labels_for_issue:
        return "CI Running"
    if "status:claimed" in labels_for_issue:
        return "Claimed"
    if "needs-reference-map" in labels_for_issue:
        return "Needs Reference Map"
    if "needs-slice-plan" in labels_for_issue:
        return "Needs Slice Plan"
    if "ready-for-agent" in labels_for_issue or "status:ready" in labels_for_issue:
        return "Ready"
    return "Intake"


def role_value(labels_for_issue: set[str], event_role: str | None = None, warnings: list[str] | None = None) -> str | None:
    role_map = {
        "role:pm": "product manager",
        "role:supervisor": "supervisor",
        "role:triager": "triager",
        "role:mapper": "mapper",
        "role:researcher": "researcher",
        "role:architect": "architect",
        "role:worker": "worker",
        "role:qa": "qa",
        "role:parity": "artifact reviewer",
        "role:auditor": "auditor",
        "role:convergence": "artifact reviewer",
        "role:reflection": "reflection",
    }
    agent_role_map = {
        "dxt_product_manager": "product manager",
        "dxt_supervisor_integrator": "supervisor",
        "dxt_issue_triager": "triager",
        "dxt_code_mapper": "mapper",
        "dxt_dbt_reference_researcher": "researcher",
        "dxt_zig_runtime_architect": "architect",
        "dxt_zig_slice_worker": "worker",
        "dxt_qa_fixture_engineer": "qa",
        "dxt_artifact_parity_reviewer": "artifact reviewer",
        "dxt_convergence_reviewer": "artifact reviewer",
        "dxt_runtime_boundary_auditor": "auditor",
        "dxt_reflection_reviewer": "reflection",
        "dxt_docs_release_curator": "docs release",
    }
    if event_role in agent_role_map:
        return agent_role_map[event_role]
    if event_role in set(role_map.values()):
        return event_role
    candidates = {value for label, value in role_map.items() if label in labels_for_issue}
    if len(candidates) == 1:
        return next(iter(candidates))
    if len(candidates) > 1 and warnings is not None:
        warnings.append(f"Agent Role has multiple role labels: {', '.join(sorted(candidates))}")
        return None
    if "area:compiler-jinja" in labels_for_issue or "area:selector" in labels_for_issue or "area:runner" in labels_for_issue:
        return "worker"
    if "area:release" in labels_for_issue or "area:docs" in labels_for_issue:
        return "docs release"
    return None


def track_value(labels_for_issue: set[str]) -> str | None:
    if "area:semantic" in labels_for_issue:
        return "semantic layer"
    if "area:cross-db" in labels_for_issue or "area:adapter-abi" in labels_for_issue:
        return "cross-db"
    if "area:duckdb" in labels_for_issue or "area:runner" in labels_for_issue:
        return "DuckDB execution"
    if "area:artifacts" in labels_for_issue:
        return "artifacts"
    if "area:release" in labels_for_issue:
        return "docs release"
    if "type:safety" in labels_for_issue or "risk:runtime-boundary" in labels_for_issue:
        return "safety"
    if "type:compat" in labels_for_issue:
        return "dbt compatibility"
    if "type:runtime" in labels_for_issue:
        return "Zig runtime"
    return None


def pattern_value(labels_for_issue: set[str]) -> str | None:
    for value in ["hierarchical", "network", "reflection", "supervisor"]:
        if f"pattern:{value}" in labels_for_issue:
            return value
    return None


def validation_value(labels_for_issue: set[str]) -> str | None:
    if "gate:zig-test" in labels_for_issue:
        return "native Zig"
    if "gate:focused-pytest" in labels_for_issue:
        return "focused pytest"
    if "gate:dbt-oracle" in labels_for_issue:
        return "dbt oracle"
    if labels_for_issue.intersection({"gate:jaffle-parse", "gate:jaffle-build", "gate:jaffle-run", "gate:jaffle-docs"}):
        return "Jaffle gate"
    if "type:safety" in labels_for_issue:
        return "safety"
    if "risk:runtime-boundary" in labels_for_issue:
        return "runtime boundary"
    if "type:ci" in labels_for_issue:
        return "CI only"
    return None


def source_grounding_value(labels_for_issue: set[str]) -> str:
    if "needs-reference-map" in labels_for_issue:
        return "missing"
    if "type:research" in labels_for_issue or "type:compat" in labels_for_issue:
        return "linked"
    return "not applicable"


def plan_update_value(labels_for_issue: set[str]) -> str:
    if "needs-slice-plan" in labels_for_issue:
        return "required"
    if "type:research" in labels_for_issue:
        return "required"
    return "not needed"


def readiness_value(labels_for_issue: set[str], event_status: str | None = None) -> str:
    if "status:blocked" in labels_for_issue or event_status == "blocked":
        return "blocked"
    if "status:review" in labels_for_issue or event_status == "review":
        return "review"
    if "status:claimed" in labels_for_issue or event_status == "claimed":
        return "claimed"
    if event_status in {"in_worktree", "in-worktree"}:
        return "in worktree"
    if event_status == "merged":
        return "merged"
    if "needs-reference-map" in labels_for_issue:
        return "needs reference map"
    if "needs-slice-plan" in labels_for_issue:
        return "needs slice plan"
    if "ready-for-agent" in labels_for_issue or "status:ready" in labels_for_issue or event_status in {"ready", "unblocked"}:
        return "ready"
    return "unknown"


def branch_value(events: list[dict[str, str]], warnings: list[str]) -> str | None:
    branch = latest_event_value(events, "branch")
    if branch is None:
        return None
    if not public_safe_inline_text(branch):
        warnings.append("Branch event value is not public-safe inline text")
        return None
    return branch


def dependency_value(issue: dict[str, object]) -> str:
    numbers = issue_dependency_numbers(issue)
    return " ".join(f"depends_on=#{number}" for number in sorted(numbers))


def issue_event_attributes(issue: dict[str, object]) -> list[dict[str, str]]:
    texts = [issue.get("body") or ""]
    comments = issue.get("comments") or []
    if isinstance(comments, list):
        for comment in comments:
            if isinstance(comment, dict):
                texts.append(comment.get("body") or "")
    events: list[dict[str, str]] = []
    for text in texts:
        if not isinstance(text, str):
            continue
        for match in AGENT_EVENT_PATTERN.finditer(text):
            attrs = {
                attr_match.group(1): attr_match.group(2)
                for attr_match in AGENT_EVENT_ATTR_PATTERN.finditer(match.group(1))
            }
            if attrs:
                events.append(attrs)
    return events


def latest_event_value(events: list[dict[str, str]], key: str) -> str | None:
    for event in reversed(events):
        value = event.get(key)
        if value:
            return value
    return None


def dependency_numbers_from_text(text: str) -> set[int]:
    numbers: set[int] = set()
    for pattern in DEPENDENCY_PATTERNS:
        for match in pattern.finditer(text):
            numbers.add(int(match.group(1)))
    return numbers


def issue_dependency_numbers(issue: dict[str, object]) -> set[int]:
    numbers: set[int] = set()
    body = issue.get("body")
    if isinstance(body, str):
        numbers.update(dependency_numbers_from_text(body))
    comments = issue.get("comments") or []
    if isinstance(comments, list):
        for comment in comments:
            if isinstance(comment, dict) and isinstance(comment.get("body"), str):
                numbers.update(dependency_numbers_from_text(comment["body"]))
    return numbers


def project_item_field_value(item: dict[str, object], field_name: str) -> str:
    if not item:
        return ""
    candidate_keys = [field_name, field_name[:1].lower() + field_name[1:]]
    for key in candidate_keys:
        value = item.get(key)
        if isinstance(value, str):
            return value
    normalized_field = normalize_project_key(field_name)
    for key, value in item.items():
        if normalize_project_key(key) == normalized_field and isinstance(value, str):
            return value
    return ""


def normalize_project_key(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value).lower())


def public_safe_inline_text(value: str) -> bool:
    if "\n" in value or "\r" in value:
        return False
    if value.startswith("/") or value.startswith("~"):
        return False
    return not any(pattern.search(value) for pattern in LOCAL_PATH_PATTERNS)


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

    item_parser = sub.add_parser("project-items")
    item_mode = item_parser.add_mutually_exclusive_group(required=True)
    item_mode.add_argument("--dry-run", action="store_true")
    item_mode.add_argument("--apply", action="store_true")
    item_parser.add_argument("--owner", default="sabino")
    item_parser.add_argument("--repo")
    item_parser.add_argument("--limit", type=int, default=100)
    item_parser.add_argument("--project-item-limit", type=int, default=1000)
    item_parser.set_defaults(func=project_items)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
