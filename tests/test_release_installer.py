"""Black-box installer download, checksum and atomic replacement coverage."""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

import pytest

INSTALLER = Path(__file__).resolve().parents[1] / "scripts/install.sh"


@pytest.fixture
def download_fixture(tmp_path):
    tools = tmp_path / "tools"
    tools.mkdir()
    assets = tmp_path / "assets"
    assets.mkdir()
    temporary = tmp_path / "temporary"
    temporary.mkdir()
    binary_dir = tmp_path / "user bin"
    binary_dir.mkdir()
    old_binary = binary_dir / "dxt"
    old_binary.write_text("Existing installation")
    log = tmp_path / "downloads.jsonl"
    tar_log = tmp_path / "extracted"
    tar = tools / "tar"
    tar.write_text(f'''#!{sys.executable}
import os,subprocess,sys
from pathlib import Path
Path(os.environ['INSTALL_TAR_LOG']).touch()
sys.exit(subprocess.run([os.environ['INSTALL_REAL_TAR'],*sys.argv[1:]]).returncode)
''')
    tar.chmod(0o755)
    curl = tools / "curl"
    curl.write_text(f'''#!{sys.executable}
import json,os,sys
from pathlib import Path
from urllib.parse import urlsplit
arguments=sys.argv[1:]
with Path(os.environ['INSTALL_DOWNLOAD_LOG']).open('a') as log:
    log.write(json.dumps(arguments)+'\\n')
url=arguments[-1]
name='releases.json' if urlsplit(url).netloc=='api.github.com' else urlsplit(url).path.rsplit('/',1)[-1]
source=Path(os.environ['INSTALL_ASSETS'])/name
if not source.is_file():sys.exit(22)
Path(arguments[arguments.index('--output')+1]).write_bytes(source.read_bytes())
''')
    curl.chmod(0o755)
    environment = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                   "TMPDIR": str(temporary), "INSTALL_ASSETS": str(assets),
                   "INSTALL_DOWNLOAD_LOG": str(log), "INSTALL_TAR_LOG": str(tar_log),
                   "INSTALL_REAL_TAR": shutil.which("tar")}
    def prepare(*, system="Darwin", machine="arm64", version="0.0.0", reported=None, tampered=False):
        (tools / "uname").write_text(f'#!/bin/sh\ncase "$1" in -s) echo {system};; -m) echo {machine};; esac\n')
        (tools / "uname").chmod(0o755)
        target = ("aarch64" if machine in {"arm64", "aarch64"} else "x86_64") + ("-macos" if system == "Darwin" else "-linux-gnu")
        root = f"dxt-v{version}-{target}"
        archive = assets / f"{root}.tar.gz"
        payload = f'#!/bin/sh\necho "{reported or version}"\n'.encode()
        with tarfile.open(archive, "w:gz") as package:
            info = tarfile.TarInfo(root + "/dxt")
            info.mode = 0o755
            info.size = len(payload)
            package.addfile(info, io.BytesIO(payload))
        digest = "0" * 64 if tampered else hashlib.sha256(archive.read_bytes()).hexdigest()
        (assets / f"{root}-SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n")
        (assets / "releases.json").write_text(json.dumps([{"tag_name": f"v{version}", "prerelease": True}]))
        return payload
    def invoke(*arguments):
        return subprocess.run(["sh", str(INSTALLER), "--bin-dir", str(binary_dir), *arguments],
                              env=environment, capture_output=True, text=True, timeout=20)
    return prepare, invoke, old_binary, temporary, log


@pytest.mark.parametrize("system,machine", [("Darwin", "arm64"), ("Darwin", "x86_64"), ("Linux", "x86_64"), ("Linux", "aarch64")])
def test_installs_selected_native_target_without_root(download_fixture, system, machine):
    prepare, invoke, binary, temporary, log = download_fixture
    payload = prepare(system=system, machine=machine)
    result = invoke("--version", "v0.0.0")
    assert result.returncode == 0, result.stdout + result.stderr
    assert binary.read_bytes() == payload
    assert binary.stat().st_mode & 0o111
    assert "Installed dxt 0.0.0" in result.stdout
    assert not list(temporary.iterdir())
    for line in log.read_text().splitlines():
        arguments = json.loads(line)
        assert arguments[arguments.index("--proto") + 1] == "=https"


def test_latest_lookup_includes_published_prereleases(download_fixture):
    prepare, invoke, binary, _, log = download_fixture
    payload = prepare(version="0.1.0-alpha.1")
    result = invoke()
    assert result.returncode == 0, result.stderr
    assert binary.read_bytes() == payload
    assert "api.github.com" in log.read_text()


@pytest.mark.parametrize("reason", ["checksum", "version"])
def test_bad_download_preserves_existing_installation_and_cleans_temporary_files(download_fixture, reason):
    prepare, invoke, binary, temporary, _ = download_fixture
    prepare(tampered=reason == "checksum", reported="9.9.9" if reason == "version" else None)
    result = invoke("--version", "0.0.0")
    assert result.returncode != 0
    assert binary.read_text() == "Existing installation"
    assert not list(temporary.iterdir())
    assert not list(binary.parent.glob(".dxt-install.*"))
    message = "SHA256 mismatch" if reason == "checksum" else "Binary version differs"
    assert message in result.stderr
    if reason == "checksum":
        assert not (binary.parent.parent / "extracted").exists()


@pytest.mark.parametrize("version", ["main", "v0.0.0/path", "v0.0.0\nother", "v0.0.0;$()"])
def test_invalid_version_never_downloads_or_overwrites(download_fixture, version):
    prepare, invoke, binary, temporary, log = download_fixture
    prepare()
    result = invoke("--version", version)
    assert result.returncode != 0
    assert "Invalid release version" in result.stderr
    assert binary.read_text() == "Existing installation"
    assert not log.exists()
    assert not list(temporary.iterdir())


def test_no_release_has_actionable_source_build_error(download_fixture):
    prepare, invoke, binary, _, log = download_fixture
    prepare()
    assets = log.parent / "assets"
    (assets / "releases.json").write_text("[]")
    result = invoke()
    assert result.returncode != 0
    assert "No published releases exist yet" in result.stderr
    assert binary.read_text() == "Existing installation"
