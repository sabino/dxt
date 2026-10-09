"""Full upstream artifact contracts and the actual documentation browser."""
from __future__ import annotations

import importlib.util
import json
import shutil
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"
spec = importlib.util.spec_from_file_location("artifact_contracts", ROOT / "scripts/validate_dbt_artifacts.py")
assert spec and spec.loader
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.fixture
def documented_project(tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    (project / "models").mkdir()
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text("name: artifacts\nversion: '1.0'\nprofile: artifacts\nmodels:\n  artifacts:\n    +materialized: table\n")
    (project / "profiles.yml").write_text(f"artifacts:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {project / 'warehouse.duckdb'}\n      schema: analytics\n      threads: 1\n")
    (project / "seeds/customers_source.csv").write_text("customer_id\n1\n2\n")
    (project / "models/customers.sql").write_text("select * from {{ ref('customers_source') }}")
    (project / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: customers\n    description: Customer directory\n    columns:\n      - name: customer_id\n        description: Customer identifier\n        tests: [not_null, unique]\n")
    (project / "models/overview.md").write_text("{% docs __overview__ %}Warehouse documentation{% enddocs %}")
    for arguments in [("build",), ("docs", "generate", "--static")]:
        result = subprocess.run([DXT, *arguments, "--project-dir", project, "--profiles-dir", project], text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
    return project


def test_complete_upstream_contracts_validate_pipeline_and_reject_seed_node_dependencies(documented_project):
    target = documented_project / "target"
    for artifact in ["manifest.json", "run_results.json", "catalog.json"]:
        contracts.assert_artifact(target / artifact)
    manifest = json.loads((target / "manifest.json").read_text())
    seed = manifest["nodes"]["seed.artifacts.customers_source"]
    assert set(seed["depends_on"]) == {"macros"}
    seed["depends_on"]["nodes"] = []
    errors = [leaf for top in contracts.validate_artifact(manifest) for leaf in contracts.focused_errors(top)]
    assert any(error.absolute_path[-1] == "depends_on" and "nodes" in error.message for error in errors)


@pytest.mark.parametrize("offline", [False, True], ids=["server", "standalone"])
def test_documentation_browser_search_columns_and_compiled_sql(documented_project, offline):
    from playwright.sync_api import sync_playwright
    browser_path = next((path for command in ["chromium", "chromium-browser", "google-chrome"] if (path := shutil.which(command))), None)
    assert browser_path, "Documentation certification requires Chromium or Chrome"
    server = None
    served_dir = documented_project / "target"
    if offline:
        served_dir = documented_project.parent / "export"
        served_dir.mkdir()
        shutil.copyfile(documented_project / "target/static_index.html", served_dir / "static_index.html")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    url = f"http://127.0.0.1:{port}" + ("/static_index.html" if offline else "/")
    server = subprocess.Popen([DXT, "docs", "serve", "--target-path", served_dir, "--port", str(port), "--no-browser"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 10
    while True:
        try:
            with urllib.request.urlopen(url, timeout=0.5):
                break
        except OSError:
            assert time.monotonic() < deadline, "Documentation server did not start"
            time.sleep(0.05)
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=browser_path, args=["--no-sandbox"])
            try:
                page = browser.new_page()
                errors = []
                requested = []
                page.on("pageerror", lambda error: errors.append(str(error)))
                page.on("request", lambda request: requested.append(request.url))
                page.goto(url)
                assert page.title() == "dxt docs"
                page.get_by_text("Warehouse documentation", exact=False).wait_for()
                page.get_by_placeholder("Search for models...").fill("customers")
                page.get_by_text("customers", exact=True).last.click()
                page.get_by_text("Customer identifier", exact=False).first.wait_for()
                assert "Customer directory" in page.locator("body").inner_text()
                page.get_by_text("Compiled", exact=True).click()
                assert "customers_source" in page.locator("body").inner_text()
                assert errors == []
                if offline:
                    assert not any("manifest.json" in address or "catalog.json" in address for address in requested)
            finally:
                browser.close()
    finally:
        if server:
            server.terminate()
            server.communicate(timeout=5)
