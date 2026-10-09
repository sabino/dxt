"""Black-box package install, lock, transport, and graph behavior through native dxt."""
from __future__ import annotations

import functools
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import threading

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"


@pytest.fixture(scope="module", autouse=True)
def build_native():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def project(path: Path, name: str, config: str = "") -> Path:
    path.mkdir(parents=True, exist_ok=True)
    (path / "dbt_project.yml").write_text(f"name: {name}\nversion: '1.0'\n{config}")
    return path


def run(path: Path, command: str = "deps", *flags: str, env=None):
    return subprocess.run(
        [DXT, command, "--project-dir", str(path), *flags],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )


def require_success(result):
    assert result.returncode == 0, result.stdout + result.stderr


def git(path: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(path), *args], text=True).strip()


def git_package(path: Path, name: str = "git_utils") -> Path:
    project(path, name)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.name", "Dependency Fixture")
    git(path, "config", "user.email", "fixture@example.org")
    (path / "models").mkdir()
    (path / "models" / "value.sql").write_text("select 1 as id\n")
    git(path, "add", ".")
    git(path, "commit", "-qm", "first version")
    return path


def test_local_transitive_install_compiles_package_macro_and_builds_model(tmp_path):
    root = project(tmp_path / "root", "consumer", "packages-install-path: vendor\n")
    common = project(tmp_path / "common", "common")
    helper = project(tmp_path / "helper", "helper")
    (root / "dependencies.yml").write_text("packages:\n  - local: ../common\n")
    (common / "packages.yml").write_text("packages:\n  - local: ../helper\n")
    (helper / "macros").mkdir()
    (helper / "macros" / "answer.sql").write_text("{% macro answer() %}41 + 1{% endmacro %}\n")
    (root / "models").mkdir()
    (root / "models" / "result.sql").write_text("select {{ helper.answer() }} as answer\n")

    require_success(run(root))
    assert {p.name for p in (root / "vendor").iterdir()} == {"common", "helper"}
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    assert lock["packages"] == [
        {"local": "../common", "name": "common"},
        {"local": "../helper", "name": "helper"},
    ]
    require_success(run(root, "compile"))
    compiled = (root / "target" / "compiled" / "consumer" / "models" / "result.sql").read_text()
    assert "41 + 1" in compiled
    if shutil.which("duckdb"):
        require_success(run(root, "build"))
        results = json.loads((root / "target" / "run_results.json").read_text())
        assert results["results"][0]["status"] == "success"


def test_local_package_inside_project_and_lock_only(tmp_path):
    root = project(tmp_path / "root", "consumer")
    project(root / "packages" / "local_utils", "local_utils")
    (root / "packages.yml").write_text("packages:\n  - local: packages/local_utils\n")
    require_success(run(root, "deps", "--lock"))
    assert (root / "package-lock.yml").exists()
    assert not (root / "dbt_packages").exists()
    require_success(run(root, "deps", "--offline"))
    assert (root / "dbt_packages" / "local_utils" / "dbt_project.yml").exists()


def test_transitive_local_paths_use_core_root_project_semantics(tmp_path):
    root = project(tmp_path / "consumer", "consumer")
    common = project(root / "packages" / "common", "common")
    project(tmp_path / "helper", "helper")
    (root / "packages.yml").write_text("packages:\n  - local: packages/common\n")
    (common / "packages.yml").write_text("packages:\n  - local: ../helper\n")
    require_success(run(root))
    assert (root / "dbt_packages" / "helper" / "dbt_project.yml").exists()


def test_absolute_local_sources_and_yaml_mapping_key_order(tmp_path):
    root = project(tmp_path / "consumer", "consumer")
    package = project(tmp_path / "utils", "utils")
    (root / "packages.yml").write_text(f"packages:\n  - name: utils\n    local: {package}\n")
    require_success(run(root))
    assert yaml.safe_load((root / "package-lock.yml").read_text())["packages"][0]["local"] == "../utils"


def test_install_path_refuses_configured_sources_and_external_symlink(tmp_path):
    root = project(tmp_path / "consumer", "consumer", "model-paths: ['custom_sql']\npackages-install-path: custom_sql\n")
    (root / "custom_sql").mkdir()
    keep = root / "custom_sql" / "keep.sql"
    keep.write_text("select 1\n")
    result = run(root)
    assert result.returncode != 0
    assert "safe project-relative generated directory" in result.stderr
    assert keep.exists()
    project(root, "consumer", "packages-install-path: linked/packages\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "linked").symlink_to(outside, target_is_directory=True)
    result = run(root)
    assert result.returncode != 0
    assert "safe project-relative generated directory" in result.stderr
    assert not (outside / "packages").exists()


def test_git_commit_lock_survives_branch_update_upgrade_and_offline_reinstall(tmp_path):
    root = project(tmp_path / "root", "consumer")
    repo = git_package(tmp_path / "repository")
    (root / "packages.yml").write_text("packages:\n  - git: ../repository\n    revision: main\n")
    first = git(repo, "rev-parse", "HEAD")
    require_success(run(root))
    initial_lock = (root / "package-lock.yml").read_text()
    assert yaml.safe_load(initial_lock)["packages"][0]["revision"] == first
    (repo / "models" / "value.sql").write_text("select 2 as id\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "second version")
    second = git(repo, "rev-parse", "HEAD")
    require_success(run(root))
    assert (root / "package-lock.yml").read_text() == initial_lock
    assert "select 1" in (root / "dbt_packages" / "git_utils" / "models" / "value.sql").read_text()
    require_success(run(root, "deps", "--upgrade"))
    assert yaml.safe_load((root / "package-lock.yml").read_text())["packages"][0]["revision"] == second
    assert "select 2" in (root / "dbt_packages" / "git_utils" / "models" / "value.sql").read_text()
    shutil.rmtree(repo)
    shutil.rmtree(root / "dbt_packages")
    require_success(run(root, "deps", "--offline"))
    assert "select 2" in (root / "dbt_packages" / "git_utils" / "models" / "value.sql").read_text()


def test_git_subdirectory_preserves_repository_layout(tmp_path):
    root = project(tmp_path / "root", "consumer")
    repo = tmp_path / "repository"
    package = git_package(repo / "dbt", "nested_utils")
    # Move Git metadata to the repository root so the dbt project is a real subdirectory.
    shutil.move(package / ".git", repo / ".git")
    (repo / "README.md").write_text("Synthetic monorepo\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "monorepo layout")
    (root / "packages.yml").write_text("packages:\n  - git: ../repository\n    revision: main\n    subdirectory: dbt\n")
    require_success(run(root))
    assert (root / "dbt_packages" / "nested_utils" / "models" / "value.sql").exists()
    assert not (root / "dbt_packages" / "nested_utils" / "README.md").exists()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


@pytest.fixture
def hub(tmp_path):
    web = tmp_path / "hub"
    web.mkdir()
    handler = functools.partial(QuietHandler, directory=str(web))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    yield web, base
    server.shutdown()
    server.server_close()
    thread.join()


def hub_package(hub, name: str, versions: dict):
    web, base = hub
    namespace, project_name = name.split("/")
    metadata = {"name": project_name, "namespace": namespace, "versions": {}}
    for version, dependencies in versions.items():
        archive = web / f"{project_name}-{version}.tar.gz"
        contents = {
            "dbt_project.yml": f"name: {project_name}\nversion: '{version}'\n",
            "models/value.sql": f"select '{version}' as version\n",
        }
        with tarfile.open(archive, "w:gz") as tar:
            for path, data in contents.items():
                encoded = data.encode()
                entry = tarfile.TarInfo(f"{project_name}-{version}/{path}")
                entry.size = len(encoded)
                tar.addfile(entry, io.BytesIO(encoded))
        metadata["versions"][version] = {
            "name": project_name,
            "packages": dependencies,
            "downloads": {"tarball": f"{base}/{archive.name}"},
        }
    endpoint = web / "api" / "v1" / namespace / f"{project_name}.json"
    endpoint.parent.mkdir(parents=True, exist_ok=True)
    endpoint.write_text(json.dumps(metadata))


def test_registry_backtracks_transitive_conflicts_and_offline_lock(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "fixture/common", {"1.0.0": [], "2.0.0": []})
    hub_package(hub, "fixture/parent", {
        "1.0.0": [{"package": "fixture/common", "version": "1.0.0"}],
        "2.0.0": [{"package": "fixture/common", "version": "2.0.0"}],
    })
    (root / "packages.yml").write_text("packages:\n  - package: fixture/parent\n    version: ['>=1.0.0', '<3.0.0']\n  - package: fixture/common\n    version: 1.0.0\n")
    env = dict(os.environ, DBT_PACKAGE_HUB_URL=hub[1])
    require_success(run(root, env=env))
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    assert {(p["package"], p["version"]) for p in lock["packages"]} == {
        ("fixture/parent", "1.0.0"), ("fixture/common", "1.0.0"),
    }
    assert "1.0.0" in (root / "dbt_packages" / "parent" / "models" / "value.sql").read_text()
    lock_bytes = (root / "package-lock.yml").read_bytes()
    shutil.rmtree(root / "dbt_packages")
    require_success(run(root, "deps", "--offline", env=env))
    assert (root / "package-lock.yml").read_bytes() == lock_bytes


def test_registry_lock_retains_version_until_upgrade(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "fixture/utils", {"1.0.0": []})
    (root / "packages.yml").write_text("packages:\n  - package: fixture/utils\n    version: ['>=1.0.0', '<2.0.0']\n")
    flags = ("--registry-url", hub[1])
    require_success(run(root, "deps", *flags))
    hub_package(hub, "fixture/utils", {"1.0.0": [], "1.1.0": [], "1.2.0-rc.1": []})
    require_success(run(root, "deps", *flags))
    assert yaml.safe_load((root / "package-lock.yml").read_text())["packages"][0]["version"] == "1.0.0"
    require_success(run(root, "deps", *flags, "--upgrade"))
    assert yaml.safe_load((root / "package-lock.yml").read_text())["packages"][0]["version"] == "1.1.0"


def test_registry_conflict_preserves_existing_install_and_lock(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "fixture/utils", {"1.0.0": [], "2.0.0": []})
    declaration = root / "packages.yml"
    declaration.write_text("packages:\n  - package: fixture/utils\n    version: 1.0.0\n")
    flags = ("--registry-url", hub[1])
    require_success(run(root, "deps", *flags))
    previous = (root / "package-lock.yml").read_bytes()
    declaration.write_text("packages:\n  - package: fixture/utils\n    version: 1.0.0\n  - package: fixture/utils\n    version: 2.0.0\n")
    result = run(root, "deps", *flags)
    assert result.returncode != 0
    assert "constraints conflict" in result.stderr
    assert (root / "package-lock.yml").read_bytes() == previous
    assert "1.0.0" in (root / "dbt_packages" / "utils" / "models" / "value.sql").read_text()


def test_dependency_cycle_and_name_collision_are_diagnostics(tmp_path):
    root = project(tmp_path / "root", "consumer")
    first = project(tmp_path / "first", "first")
    second = project(tmp_path / "second", "second")
    (root / "packages.yml").write_text("packages:\n  - local: ../first\n")
    (first / "packages.yml").write_text("packages:\n  - local: ../second\n")
    (second / "packages.yml").write_text("packages:\n  - local: ../first\n")
    result = run(root)
    assert result.returncode != 0
    assert "contains a cycle" in result.stderr
    assert not (root / "package-lock.yml").exists()
    (first / "packages.yml").unlink()
    (second / "packages.yml").unlink()
    project(second, "first")
    (root / "packages.yml").write_text("packages:\n  - local: ../first\n  - local: ../second\n")
    result = run(root)
    assert result.returncode != 0
    assert "duplicate project names" in result.stderr


def test_missing_local_offline_cache_and_invalid_declaration(tmp_path):
    root = project(tmp_path / "root", "consumer")
    declaration = root / "packages.yml"
    declaration.write_text("packages:\n  - local: ../missing\n")
    result = run(root)
    assert "local package directory does not exist" in result.stderr
    declaration.write_text("packages:\n  - package: fixture/utils\n    version: 1.0.0\n")
    result = run(root, "deps", "--offline")
    assert "offline package cache is incomplete" in result.stderr
    declaration.write_text("packages:\n  - package: fixture/utils\n")
    result = run(root)
    assert "invalid package declaration" in result.stderr
    declaration.write_text("packages: []\n")
    (root / "dependencies.yml").write_text("packages: []\n")
    result = run(root)
    assert "either packages.yml or dependencies.yml" in result.stderr


def test_archive_path_escape_is_rejected_before_installation(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "fixture/unsafe", {"1.0.0": []})
    with tarfile.open(hub[0] / "unsafe-1.0.0.tar.gz", "w:gz") as tar:
        for name in ("unsafe/dbt_project.yml", "../outside.sql"):
            encoded = b"name: unsafe\n"
            entry = tarfile.TarInfo(name)
            entry.size = len(encoded)
            tar.addfile(entry, io.BytesIO(encoded))
    (root / "packages.yml").write_text("packages:\n  - package: fixture/unsafe\n    version: 1.0.0\n")
    result = run(root, "deps", "--registry-url", hub[1])
    assert result.returncode != 0
    assert "unsafe paths" in result.stderr
    assert not (root / "dbt_packages").exists()
    assert not (root / "outside.sql").exists()


def test_package_environment_values_and_empty_dependency_set(tmp_path):
    root = project(tmp_path / "root", "consumer")
    project(tmp_path / "utils", "utils")
    (root / "packages.yml").write_text("packages:\n  - local: \"{{ env_var('FIXTURE_PACKAGE_PATH') }}\"\n")
    require_success(run(root, env=dict(os.environ, FIXTURE_PACKAGE_PATH="../utils")))
    (root / "packages.yml").write_text("packages: []\n")
    require_success(run(root))
    assert list((root / "dbt_packages").iterdir()) == []
    assert yaml.safe_load((root / "package-lock.yml").read_text())["packages"] == []


def test_git_revision_conflict_rejected(tmp_path):
    root = project(tmp_path / "root", "consumer")
    repo = git_package(tmp_path / "repository")
    first = git(repo, "rev-parse", "HEAD")
    (repo / "models" / "value.sql").write_text("select 2 as id\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "second version")
    (root / "packages.yml").write_text(f"packages:\n  - git: ../repository\n    revision: {first}\n  - git: ../repository\n    revision: main\n")
    result = run(root)
    assert result.returncode != 0
    assert "constraints conflict" in result.stderr


def test_core_reads_native_lock_and_declaration_fingerprint(tmp_path):
    pytest.importorskip("dbt.cli.main")
    from dbt.config.project import package_config_from_data
    from dbt.task.deps import _create_sha1_hash

    root = project(tmp_path / "root", "consumer")
    project(tmp_path / "utils", "utils")
    declaration = {"packages": [{"local": "../utils"}]}
    (root / "packages.yml").write_text(yaml.safe_dump(declaration))
    require_success(run(root))
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    actual_hash = lock["sha1_hash"]
    # Core mutates its inputs when attaching unrendered package definitions.
    config = package_config_from_data(json.loads(json.dumps(declaration)), declaration)
    assert actual_hash == _create_sha1_hash(config.packages)
    locked = package_config_from_data(lock)
    assert locked.packages[0].name == "utils"


def assert_core_fingerprint(root, declaration, variables=None, render=True):
    pytest.importorskip("dbt.cli.main")
    from dbt.config.project import package_config_from_data
    from dbt.config.renderer import PackageRenderer
    from dbt.task.deps import _create_sha1_hash
    from dbt_common.context import set_invocation_context

    set_invocation_context(dict(os.environ))
    raw = yaml.safe_load(declaration)
    rendered = PackageRenderer(variables or {}).render_data(raw) if render else json.loads(json.dumps(raw))
    config = package_config_from_data(rendered, raw)
    assert yaml.safe_load((root / "package-lock.yml").read_text())["sha1_hash"] == _create_sha1_hash(config.packages)


def test_flow_yaml_anchors_merges_and_safe_tags_install_deterministically(tmp_path):
    root = project(tmp_path / "root", "consumer", "packages-install-path: &install vendor\n")
    project(tmp_path / "utils", "utils")
    source = "packages: [ &utils {local: !!str ../utils, name: utils}, {<<: *utils} ]\n"
    (root / "packages.yml").write_text(source)
    require_success(run(root))
    assert (root / "vendor" / "utils" / "dbt_project.yml").exists()
    assert len(yaml.safe_load((root / "package-lock.yml").read_text())["packages"]) == 1
    assert_core_fingerprint(root, source)
    require_success(run(root, "deps", "--offline"))


def test_general_package_jinja_vars_filters_control_and_unrendered_hash(tmp_path):
    root = project(tmp_path / "root", "consumer")
    project(tmp_path / "utils", "utils")
    source = """packages:
  - local: >-
      {% set prefix = var('base') %}{% if env_var('FIXTURE_PACKAGE_ENABLED', 'yes') == 'yes' %}{{ prefix }}{% for letter in ['u','t','i','l','s'] %}{{ letter }}{% endfor %}{% else %}missing{% endif %}
    name: "{{ 'UTILS' | lower }}"
"""
    (root / "packages.yml").write_text(source)
    variables = {"base": "../"}
    require_success(run(root, "deps", "--vars", yaml.safe_dump(variables)))
    assert (root / "dbt_packages" / "utils" / "dbt_project.yml").exists()
    assert_core_fingerprint(root, source, variables)
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    assert "{% set" in lock["packages"][0]["local"]
    require_success(run(root, "deps", "--offline", "--vars", yaml.safe_dump(variables)))
    assert run(root, "deps", "--vars", "[not, a, mapping]").returncode != 0


def test_native_package_versions_and_boolean_markers_match_core(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "fixture/native", {"1.0.0": [], "1.1.0-rc.1": []})
    source = """packages:
  - package: "{{ var('namespace') ~ '/native' }}"
    version: "{{ var('versions') }}"
    install_prerelease: "{{ true | as_bool }}"
"""
    variables = {"namespace": "fixture", "versions": [">=1.0.0", "<2.0.0"]}
    (root / "packages.yml").write_text(source)
    require_success(run(root, "deps", "--registry-url", hub[1], "--vars", yaml.safe_dump(variables)))
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    assert lock["packages"][0]["version"] == "1.1.0-rc.1"
    assert_core_fingerprint(root, source, variables)


def test_dependencies_yaml_remains_static_as_core_requires(tmp_path):
    root = project(tmp_path / "root", "consumer")
    project(tmp_path / "utils", "utils")
    (root / "dependencies.yml").write_text("packages: [{local: \"{{ var('path') }}\"}]\n")
    result = run(root, "deps", "--vars", "{path: ../utils}")
    assert result.returncode != 0
    assert "local package directory does not exist" in result.stderr
    source = "packages: [{local: ../utils}]\n"
    (root / "dependencies.yml").write_text(source)
    require_success(run(root))
    assert_core_fingerprint(root, source, render=False)


def test_tarball_declared_package_lock_offline_and_archive_validation(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "fixture/tar_utils", {"1.0.0": []})
    source = f"packages: [{{tarball: '{hub[1]}/tar_utils-1.0.0.tar.gz', name: tar_utils}}]\n"
    (root / "packages.yml").write_text(source)
    require_success(run(root))
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    assert lock["packages"] == [{"tarball": f"{hub[1]}/tar_utils-1.0.0.tar.gz", "name": "tar_utils"}]
    assert_core_fingerprint(root, source)
    (hub[0] / "tar_utils-1.0.0.tar.gz").unlink()
    shutil.rmtree(root / "dbt_packages")
    require_success(run(root, "deps", "--offline"))
    assert (root / "dbt_packages" / "tar_utils" / "models" / "value.sql").exists()


def test_private_git_uses_normal_git_credentials_and_locks_commit(tmp_path):
    root = project(tmp_path / "root", "consumer")
    repo = git_package(tmp_path / "repository", "private_utils")
    commit = git(repo, "rev-parse", "HEAD")
    # A normal Git URL rewrite proves native subprocesses inherit Git config
    # without placing credentials in declarations or product diagnostics.
    git_config = tmp_path / "gitconfig"
    git_config.write_text(f'[url "{repo}"]\n\tinsteadOf = https://github.com/fixture/private.git\n')
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=str(git_config), GIT_CONFIG_NOSYSTEM="1")
    source = "packages: [{private: fixture/private, provider: github, revision: main}]\n"
    (root / "packages.yml").write_text(source)
    require_success(run(root, env=environment))
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    assert lock["packages"] == [{"private": "fixture/private", "name": "private_utils", "revision": commit, "provider": "github"}]
    assert_core_fingerprint(root, source)
    require_success(run(root, "deps", "--offline", env=environment))


def test_hub_redirects_unify_alias_constraints_and_keep_core_lock_source(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "renamed/utils", {"1.0.0": [], "1.1.0": []})
    old = hub[0] / "api" / "v1" / "legacy" / "old.json"
    old.parent.mkdir(parents=True)
    metadata = json.loads((hub[0] / "api" / "v1" / "renamed" / "utils.json").read_text())
    metadata.update(namespace="legacy", name="old", redirectnamespace="renamed", redirectname="utils")
    old.write_text(json.dumps(metadata))
    (root / "packages.yml").write_text("packages: [{package: legacy/old, version: '>=1.0.0'}, {package: renamed/utils, version: '<1.1.0'}]\n")
    result = run(root, "deps", "--registry-url", hub[1])
    require_success(result)
    assert "renamed to renamed/utils" in result.stderr
    lock = yaml.safe_load((root / "package-lock.yml").read_text())
    assert lock["packages"] == [{"package": "legacy/old", "name": "utils", "version": "1.0.0"}]
    require_success(run(root, "deps", "--registry-url", hub[1], "--offline"))


def test_hub_metadata_only_redirects_follow_and_cycles_fail_safely(tmp_path, hub):
    root = project(tmp_path / "root", "consumer")
    hub_package(hub, "fixture/utils", {"1.0.0": []})
    redirect = hub[0] / "api" / "v1" / "legacy" / "old.json"
    redirect.parent.mkdir(parents=True)
    redirect.write_text(json.dumps({"redirectnamespace": "fixture", "redirectname": "utils"}))
    (root / "packages.yml").write_text("packages: [{package: legacy/old, version: 1.0.0}]\n")
    require_success(run(root, "deps", "--registry-url", hub[1]))
    redirect.write_text(json.dumps({"redirectnamespace": "legacy", "redirectname": "other"}))
    (redirect.parent / "other.json").write_text(json.dumps({"redirectname": "old"}))
    result = run(root, "deps", "--registry-url", hub[1], "--upgrade")
    assert result.returncode != 0
    assert "redirect contains a cycle" in result.stderr


def test_git_transport_never_prints_credentialed_source(tmp_path):
    root = project(tmp_path / "root", "consumer")
    credential = "fixture-secret-password"
    (root / "packages.yml").write_text(f"packages: [{{git: 'https://user:{credential}@127.0.0.1:1/missing.git', revision: main}}]\n")
    result = run(root, env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
    assert result.returncode != 0
    assert credential not in result.stdout + result.stderr
    assert "Git package transport failed" in result.stderr


def test_unicode_and_numeric_revisions_keep_core_fingerprints(tmp_path):
    root = project(tmp_path / "root", "consumer")
    repo = git_package(tmp_path / "repository", "git_utils")
    git(repo, "tag", "1.0")
    source = "packages: [{git: ../repository, revision: 1.0, warn-unpinned: null}]\n"
    (root / "packages.yml").write_text(source)
    require_success(run(root))
    assert_core_fingerprint(root, source)
    source = "packages: [{git: ../repository, revision: \"{{ var('revision') }}\"}]\n"
    variables = {"revision": 1.0}
    (root / "packages.yml").write_text(source)
    require_success(run(root, "deps", "--vars", yaml.safe_dump(variables)))
    assert_core_fingerprint(root, source, variables)
    project(tmp_path / "utils_☃🚀", "utils")
    source = "packages: [{local: '../utils_☃🚀'}]\n"
    (root / "packages.yml").write_text(source)
    require_success(run(root))
    assert_core_fingerprint(root, source)


def test_invalid_dependency_yaml_reports_file_and_source_mark(tmp_path):
    root = project(tmp_path / "root", "consumer")
    (root / "packages.yml").write_text("packages:\n  - {local: ../utils\n")
    result = run(root)
    assert result.returncode != 0
    assert "invalid YAML in packages.yml at line 3, column 1" in result.stderr
    assert not (root / "dbt_packages").exists()
