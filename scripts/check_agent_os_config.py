from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / ".codex" / "config.toml"
LABELS_PATH = ROOT / ".github" / "agent-team" / "labels.json"
PROJECT_PATH = ROOT / ".github" / "agent-team" / "project.json"
ORCHESTRATOR_PATH = ROOT / ".github" / "agent-team" / "orchestrator.json"
SEED_ISSUES_PATH = ROOT / ".github" / "agent-team" / "seed_issues.json"
ISSUE_TEMPLATE_DIR = ROOT / ".github" / "ISSUE_TEMPLATE"

EXPECTED_ISSUE_FORMS = {
    "config.yml",
    "01_compatibility_slice.yml",
    "02_zig_runtime_slice.yml",
    "03_artifact_parity_review.yml",
    "04_research_spike.yml",
    "05_ci_docs_release.yml",
    "06_supervisor_batch.yml",
}

EXPECTED_AGENTS = {
    "dxt_artifact_parity_reviewer",
    "dxt_code_mapper",
    "dxt_compatibility_curator",
    "dxt_convergence_reviewer",
    "dxt_dbt_reference_researcher",
    "dxt_docs_release_curator",
    "dxt_execution_adapter_specialist",
    "dxt_issue_triager",
    "dxt_jinja_macro_specialist",
    "dxt_network_coordinator",
    "dxt_product_manager",
    "dxt_qa_fixture_engineer",
    "dxt_reflection_reviewer",
    "dxt_runtime_boundary_auditor",
    "dxt_selector_state_specialist",
    "dxt_semantic_crossdb_planner",
    "dxt_supervisor_integrator",
    "dxt_zig_runtime_architect",
    "dxt_zig_slice_worker",
}

LOCAL_PATH_PATTERNS = [
    re.compile("/home/" + "sabino"),
    re.compile("/media/" + "sabino"),
    re.compile("SABINO" + "_EXT4"),
]


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path.relative_to(ROOT)} is invalid JSON: {exc}") from exc


def check_no_local_paths(path: Path, findings: list[str]) -> None:
    text = path.read_text(encoding="utf-8", errors="ignore")
    for pattern in LOCAL_PATH_PATTERNS:
        match = pattern.search(text)
        if match:
            line = text.count("\n", 0, match.start()) + 1
            findings.append(f"{path.relative_to(ROOT)}:{line}: local path pattern")


def validate_labels(findings: list[str]) -> set[str]:
    labels = load_json(LABELS_PATH)
    if not isinstance(labels, list):
        findings.append(".github/agent-team/labels.json must be a list")
        return set()

    names: set[str] = set()
    for index, label in enumerate(labels):
        if not isinstance(label, dict):
            findings.append(f"labels[{index}] must be an object")
            continue
        name = label.get("name")
        color = label.get("color")
        description = label.get("description")
        if not isinstance(name, str) or not name:
            findings.append(f"labels[{index}] missing name")
        elif name in names:
            findings.append(f"duplicate label: {name}")
        else:
            names.add(name)
        if not isinstance(color, str) or not re.fullmatch(r"[0-9a-fA-F]{6}", color):
            findings.append(f"label {name!r} has invalid color")
        if not isinstance(description, str) or not description:
            findings.append(f"label {name!r} missing description")
    return names


def validate_project(findings: list[str]) -> None:
    project = load_json(PROJECT_PATH)
    if not isinstance(project, dict):
        findings.append(".github/agent-team/project.json must be an object")
        return
    if not isinstance(project.get("title"), str) or not project["title"]:
        findings.append("project.json missing title")
    fields = project.get("fields")
    if not isinstance(fields, list):
        findings.append("project.json fields must be a list")
        return
    seen: set[str] = set()
    for field in fields:
        if not isinstance(field, dict):
            findings.append("project field must be an object")
            continue
        name = field.get("name")
        typ = field.get("type")
        if not isinstance(name, str) or not name:
            findings.append("project field missing name")
        elif name in seen:
            findings.append(f"duplicate project field: {name}")
        else:
            seen.add(name)
        if typ not in {"TEXT", "SINGLE_SELECT", "DATE", "NUMBER"}:
            findings.append(f"project field {name!r} has invalid type {typ!r}")
        if typ == "SINGLE_SELECT":
            options = field.get("options")
            if not isinstance(options, list) or not all(isinstance(option, str) and option for option in options):
                findings.append(f"project field {name!r} needs string options")


def validate_orchestrator(label_names: set[str], findings: list[str]) -> None:
    config = load_json(ORCHESTRATOR_PATH)
    if not isinstance(config, dict):
        findings.append(".github/agent-team/orchestrator.json must be an object")
        return

    required_strings = ["default_profile", "default_model", "default_base", "worktree_root", "fallback_agent"]
    for key in required_strings:
        if not isinstance(config.get(key), str) or not config[key]:
            findings.append(f"orchestrator.json missing {key}")

    for key in ["ready_labels", "blocked_labels"]:
        values = config.get(key)
        if not isinstance(values, list) or not values:
            findings.append(f"orchestrator.json {key} must be a non-empty list")
            continue
        for label in values:
            if label not in label_names:
                findings.append(f"orchestrator.json {key} references unknown label {label!r}")

    roles = config.get("role_map")
    if not isinstance(roles, list) or not roles:
        findings.append("orchestrator.json role_map must be a non-empty list")
        return
    for index, role in enumerate(roles):
        if not isinstance(role, dict):
            findings.append(f"orchestrator role_map[{index}] must be an object")
            continue
        label = role.get("label")
        agent = role.get("agent")
        mode = role.get("mode")
        sandbox = role.get("sandbox")
        if label not in label_names:
            findings.append(f"orchestrator role_map[{index}] references unknown label {label!r}")
        if not isinstance(agent, str) or not agent:
            findings.append(f"orchestrator role_map[{index}] missing agent")
        if mode not in {"plan", "product", "research", "map", "implement", "review", "reflect", "docs", "qa"}:
            findings.append(f"orchestrator role_map[{index}] has invalid mode {mode!r}")
        if sandbox not in {"read-only", "workspace-write", "danger-full-access"}:
            findings.append(f"orchestrator role_map[{index}] has invalid sandbox {sandbox!r}")

    product_manager_sandbox = config.get("product_manager_sandbox")
    if product_manager_sandbox is not None and product_manager_sandbox not in {"read-only", "workspace-write", "danger-full-access"}:
        findings.append(f"orchestrator.json has invalid product_manager_sandbox {product_manager_sandbox!r}")


def validate_issue_forms(label_names: set[str], findings: list[str]) -> None:
    actual = {path.name for path in ISSUE_TEMPLATE_DIR.glob("*") if path.is_file()}
    missing = EXPECTED_ISSUE_FORMS - actual
    for filename in sorted(missing):
        findings.append(f"missing issue template: {filename}")

    for path in sorted(ISSUE_TEMPLATE_DIR.glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        if path.name != "config.yml":
            for key in ["name:", "description:", "title:", "labels:", "body:"]:
                if key not in text:
                    findings.append(f"{path.relative_to(ROOT)} missing {key}")
        match = re.search(r"labels:\s*\[(.*?)\]", text)
        if match:
            labels = [item.strip().strip("\"'") for item in match.group(1).split(",") if item.strip()]
            for label in labels:
                if label not in label_names:
                    findings.append(f"{path.relative_to(ROOT)} references unknown label {label!r}")
        check_no_local_paths(path, findings)


def validate_seed_issues(label_names: set[str], findings: list[str]) -> None:
    issues = load_json(SEED_ISSUES_PATH)
    if not isinstance(issues, list):
        findings.append("seed_issues.json must be a list")
        return
    titles: set[str] = set()
    for index, issue in enumerate(issues):
        if not isinstance(issue, dict):
            findings.append(f"seed_issues[{index}] must be an object")
            continue
        title = issue.get("title")
        labels = issue.get("labels")
        body = issue.get("body")
        if not isinstance(title, str) or not title:
            findings.append(f"seed_issues[{index}] missing title")
        elif title in titles:
            findings.append(f"duplicate seed issue title: {title}")
        else:
            titles.add(title)
        if not isinstance(body, str) or not body:
            findings.append(f"seed issue {title!r} missing body")
        if not isinstance(labels, list):
            findings.append(f"seed issue {title!r} labels must be a list")
        else:
            for label in labels:
                if label not in label_names:
                    findings.append(f"seed issue {title!r} references unknown label {label!r}")


def validate_agents(findings: list[str]) -> None:
    names: set[str] = set()
    for path in sorted((ROOT / ".codex" / "agents").glob("*.toml")):
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as exc:
            findings.append(f"{path.relative_to(ROOT)} invalid TOML: {exc}")
            continue
        name = data.get("name")
        if not isinstance(name, str) or not name:
            findings.append(f"{path.relative_to(ROOT)} missing name")
        else:
            names.add(name)
        for key in ["description", "developer_instructions"]:
            if not isinstance(data.get(key), str) or not data[key]:
                findings.append(f"{path.relative_to(ROOT)} missing {key}")
        nicknames = data.get("nickname_candidates")
        if nicknames is not None:
            validate_nicknames(path, nicknames, findings)
    for name in sorted(EXPECTED_AGENTS - names):
        findings.append(f"missing expected agent: {name}")


def validate_nicknames(path: Path, nicknames: object, findings: list[str]) -> None:
    if not isinstance(nicknames, list) or not nicknames:
        findings.append(f"{path.relative_to(ROOT)} nickname_candidates must be a non-empty list")
        return
    seen: set[str] = set()
    for nickname in nicknames:
        if not isinstance(nickname, str) or not re.fullmatch(r"[A-Za-z0-9 _-]+", nickname):
            findings.append(f"{path.relative_to(ROOT)} has invalid nickname {nickname!r}")
            continue
        if nickname in seen:
            findings.append(f"{path.relative_to(ROOT)} duplicate nickname {nickname!r}")
        seen.add(nickname)


def validate_codex_config(findings: list[str]) -> None:
    if not CONFIG_PATH.exists():
        findings.append("missing .codex/config.toml")
        return
    try:
        data = tomllib.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        findings.append(f".codex/config.toml invalid TOML: {exc}")
        return
    agents = data.get("agents")
    if not isinstance(agents, dict):
        findings.append(".codex/config.toml missing [agents]")
        return
    if agents.get("max_threads") != 18:
        findings.append(".codex/config.toml agents.max_threads should be 18")
    if agents.get("max_depth") != 2:
        findings.append(".codex/config.toml agents.max_depth should be 2")
    if agents.get("job_max_runtime_seconds") != 7200:
        findings.append(".codex/config.toml agents.job_max_runtime_seconds should be 7200")

    for name in EXPECTED_AGENTS:
        entry = agents.get(name)
        if not isinstance(entry, dict):
            findings.append(f".codex/config.toml missing [agents.{name}]")
            continue
        config_file = entry.get("config_file")
        description = entry.get("description")
        if not isinstance(description, str) or not description:
            findings.append(f".codex/config.toml agents.{name} missing description")
        if not isinstance(config_file, str) or not config_file:
            findings.append(f".codex/config.toml agents.{name} missing config_file")
        else:
            path = CONFIG_PATH.parent / config_file
            if not path.exists():
                findings.append(f".codex/config.toml agents.{name} config_file missing: {config_file}")
        validate_nicknames(CONFIG_PATH, entry.get("nickname_candidates"), findings)
    check_no_local_paths(CONFIG_PATH, findings)


def validate_docs(findings: list[str]) -> None:
    for rel in [
        ".codex/config.toml",
        "docs/AGENT_OS.md",
        "docs/AGENT_PROTOCOLS.md",
        "docs/GITHUB_PROJECTS.md",
        "docs/MULTI_AGENT_WORKFLOW.md",
        ".github/PULL_REQUEST_TEMPLATE.md",
    ]:
        path = ROOT / rel
        if not path.exists():
            findings.append(f"missing {rel}")
        else:
            check_no_local_paths(path, findings)


def validate_config() -> list[str]:
    findings: list[str] = []
    label_names = validate_labels(findings)
    validate_project(findings)
    validate_orchestrator(label_names, findings)
    validate_issue_forms(label_names, findings)
    validate_seed_issues(label_names, findings)
    validate_agents(findings)
    validate_codex_config(findings)
    validate_docs(findings)
    return findings


def main() -> int:
    findings = validate_config()
    if findings:
        print("Agent OS config check failed:")
        print("\n".join(findings))
        return 1
    print("Agent OS config check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
