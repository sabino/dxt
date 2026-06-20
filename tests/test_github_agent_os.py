from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "github_agent_os.py"
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("github_agent_os", SCRIPT)
assert SPEC is not None
github_agent_os = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(github_agent_os)


def test_desired_project_values_from_labels_and_agent_events() -> None:
    issue = {
        "number": 160,
        "body": "depends_on=#158",
        "labels": [
            {"name": "ready-for-agent"},
            {"name": "needs-reference-map"},
            {"name": "role:pm"},
            {"name": "role:supervisor"},
            {"name": "status:claimed"},
            {"name": "pattern:network"},
            {"name": "type:ci"},
        ],
        "comments": [
            {
                "body": (
                    "<!-- dxt-agent-event:v1 status=claimed "
                    "role=dxt_supervisor_integrator "
                    "branch=agent/issue-160-project-fields -->"
                )
            }
        ],
    }

    values, warnings = github_agent_os.desired_project_values(issue)

    assert warnings == []
    assert values["Agent Status"] == "Claimed"
    assert values["Agent Role"] == "supervisor"
    assert values["Pattern"] == "network"
    assert values["Validation"] == "CI only"
    assert values["Source Grounding"] == "missing"
    assert values["Readiness"] == "claimed"
    assert values["Branch"] == "agent/issue-160-project-fields"
    assert values["Dependencies"] == "depends_on=#158"


def test_ambiguous_role_labels_are_skipped_without_event_role() -> None:
    issue = {
        "number": 160,
        "labels": [{"name": "role:pm"}, {"name": "role:supervisor"}],
        "comments": [],
    }

    values, warnings = github_agent_os.desired_project_values(issue)

    assert values["Agent Role"] is None
    assert warnings == ["Agent Role has multiple role labels: product manager, supervisor"]


def test_project_item_field_value_matches_gh_project_json_keys() -> None:
    item = {
        "agent Status": "Needs Slice Plan",
        "pLAN Update": "required",
        "source Grounding": "linked",
        "branch": "agent/issue-160-project-fields",
    }

    assert github_agent_os.project_item_field_value(item, "Agent Status") == "Needs Slice Plan"
    assert github_agent_os.project_item_field_value(item, "PLAN Update") == "required"
    assert github_agent_os.project_item_field_value(item, "Source Grounding") == "linked"
    assert github_agent_os.project_item_field_value(item, "Branch") == "agent/issue-160-project-fields"


def test_dependency_numbers_include_comment_conventions() -> None:
    issue = {
        "body": "blocked by: #158",
        "comments": [
            {"body": "<!-- dxt-agent-event:v1 status=blocked depends_on=#157 -->"},
            {"body": "depends on: #159"},
        ],
    }

    assert github_agent_os.issue_dependency_numbers(issue) == {157, 158, 159}
    assert github_agent_os.dependency_value(issue) == "depends_on=#157 depends_on=#158 depends_on=#159"
