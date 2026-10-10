"""Release-header and checksum/extraction regressions without native builds."""
from __future__ import annotations

import hashlib
import importlib
import tarfile
from pathlib import Path

import pytest
import yaml

from test_public_safety import add_tar_file, elf_header, release_archive, write_release_archive


@pytest.fixture
def install_module(monkeypatch):
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[1] / "scripts"))
    return importlib.import_module("check_install")


def checksum_file(tmp_path, archive, *, digest=None, extra=""):
    path = tmp_path / "SHA256SUMS.txt"
    digest = digest or hashlib.sha256(archive.read_bytes()).hexdigest()
    path.write_text(f"{digest}  {archive.name}\n{extra}", encoding="utf-8")
    return path


@pytest.mark.parametrize("target,machine", [("x86_64-linux-gnu", 62), ("aarch64-linux-gnu", 183)])
@pytest.mark.parametrize("file_type", [2, 3])
def test_declared_architecture_accepts_executable_and_pie(tmp_path, target, machine, file_type):
    archive = tmp_path / f"dxt-v0.0.0-{target}.tar.gz"
    write_release_archive(archive, binary=elf_header(machine, file_type=file_type))
    assert release_archive.check_archive(
        archive, release_archive.infer_expectation(archive, "0.0.0", target)
    ) == []


@pytest.mark.parametrize("target,machine", [("x86_64-linux-gnu", 183), ("aarch64-linux-gnu", 62)])
def test_cross_labeled_elf_is_rejected(tmp_path, target, machine):
    archive = tmp_path / f"dxt-v0.0.0-{target}.tar.gz"
    write_release_archive(archive, binary=elf_header(machine))
    findings = release_archive.check_archive(
        archive, release_archive.infer_expectation(archive, "0.0.0", None)
    )
    assert any(f"ELF machine {machine} does not match target {target}" in row for row in findings)


@pytest.mark.parametrize("length", [0, 4, 16, 19, 63])
def test_truncated_elf_header_is_rejected(length):
    assert "truncated ELF64 header" in release_archive.check_elf(elf_header()[:length], "x86_64-linux-gnu", "binary")[0]


@pytest.mark.parametrize("offset,value,message", [
    (0, 0, "not an ELF executable"), (4, 1, "ELF64 class"),
    (5, 2, "little-endian"), (6, 0, "invalid ELF version"),
    (16, 1, "not an ELF executable or PIE"), (18, 3, "does not match target"),
    (20, 0, "invalid ELF version"), (52, 63, "invalid ELF64 header size"),
])
def test_malformed_elf_header_is_rejected(offset, value, message):
    data = bytearray(elf_header())
    data[offset] = value
    assert any(message in row for row in release_archive.check_elf(data, "x86_64-linux-gnu", "binary"))


def test_unknown_target_is_not_silently_unchecked(tmp_path):
    with pytest.raises(ValueError, match="unsupported release target"):
        release_archive.infer_expectation(tmp_path / "dxt-v0.0.0-mips-linux-gnu.tar.gz", "0.0.0", None)


@pytest.mark.parametrize("member", ["dxt", "docs/licenses/libyaml-LICENSE"])
def test_required_binary_and_notices_must_be_files(tmp_path, member):
    archive_path = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    with tarfile.open(archive_path, "w:gz") as archive:
        info = tarfile.TarInfo(f"dxt-v0.0.0-x86_64-linux-gnu/{member}")
        info.type = tarfile.DIRTYPE
        archive.addfile(info)
    findings = release_archive.check_archive(
        archive_path, release_archive.infer_expectation(archive_path, "0.0.0", None)
    )
    assert any("not a regular file" in row for row in findings)


def test_non_executable_metadata_still_rejected(tmp_path):
    archive_path = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    with tarfile.open(archive_path, "w:gz") as archive:
        add_tar_file(archive, "dxt-v0.0.0-x86_64-linux-gnu/dxt", elf_header(), 0o644)
    findings = release_archive.check_archive(
        archive_path, release_archive.infer_expectation(archive_path, "0.0.0", None)
    )
    assert any("not executable in archive metadata" in row for row in findings)


@pytest.mark.parametrize("payload", [b"not a tar archive", b"\x1f\x8b\x08\x00"])
def test_malformed_archive_returns_findings(tmp_path, payload):
    archive = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    archive.write_bytes(payload)
    findings = release_archive.check_archive(
        archive, release_archive.infer_expectation(archive, "0.0.0", None)
    )
    assert len(findings) == 1 and "could not read archive" in findings[0]


def test_install_selects_one_archive_from_published_checksum_set(tmp_path, install_module):
    archive = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    write_release_archive(archive)
    checksums = checksum_file(tmp_path, archive, extra=f"{'a' * 64}  dxt-v0.0.0-aarch64-linux-gnu.tar.gz\n")
    install = tmp_path / "extracted"
    binary = install_module.extract_verified_archive(archive, checksums, install, "0.0.0")
    assert binary.read_bytes() == elf_header()
    assert binary.stat().st_mode & 0o111
    # Publication must still reject entries outside the complete supplied archive set.
    assert any("unexpected file" in row for row in release_archive.check_checksums(checksums, [archive]))


@pytest.mark.parametrize("checksum_case", ["mismatch", "missing", "duplicate", "malformed", "path", "missing_file"])
def test_bad_checksum_prevents_archive_open_and_certification(tmp_path, monkeypatch, install_module, checksum_case):
    archive = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    write_release_archive(archive)
    checksums = checksum_file(tmp_path, archive)
    if checksum_case == "mismatch":
        archive.write_bytes(archive.read_bytes() + b"tampered")
    elif checksum_case == "missing":
        checksums.write_text(f"{'a' * 64}  other.tar.gz\n")
    elif checksum_case == "duplicate":
        checksums.write_text(checksums.read_text() * 2)
    elif checksum_case == "malformed":
        checksums.write_text(checksums.read_text() + "bad-digest  other.tar.gz\n")
    elif checksum_case == "path":
        checksums.write_text(checksums.read_text() + f"{'a' * 64}  ../other.tar.gz\n")
    else:
        checksums.unlink()
    library = tmp_path / "library.so"
    library.touch()
    monkeypatch.setenv("DXT_DUCKDB_LIBRARY", str(library))
    monkeypatch.setattr(install_module.tarfile, "open", lambda *a, **kw: pytest.fail("archive opened before checksum acceptance"))
    monkeypatch.setattr(install_module, "certify_adapter", lambda *a, **kw: pytest.fail("adapter certification started on rejected bytes"))
    with pytest.raises(ValueError):
        install_module.main(["--archive", str(archive), "--checksum-file", str(checksums)])


@pytest.mark.parametrize("args", [["--archive", "candidate.tar.gz"], ["--checksum-file", "SHA256SUMS.txt"]])
def test_install_requires_archive_and_checksum_together(install_module, args):
    with pytest.raises(SystemExit) as error:
        install_module.main(args)
    assert error.value.code == 2


def test_matching_checksum_does_not_bypass_elf_validation(tmp_path, install_module):
    archive = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    write_release_archive(archive, binary=elf_header(183))
    checksums = checksum_file(tmp_path, archive)
    install = tmp_path / "extracted"
    with pytest.raises(ValueError, match="does not match target"):
        install_module.extract_verified_archive(archive, checksums, install, "0.0.0")
    assert not install.exists()


def test_packaging_remains_deterministic_and_checks_architecture(tmp_path, monkeypatch):
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[1] / "scripts"))
    package_release = importlib.import_module("package_release")
    binary = tmp_path / "dxt"
    binary.write_bytes(elf_header())
    first = package_release.package(binary, tmp_path / "first", "0.0.0", "x86_64-linux-gnu")
    second = package_release.package(binary, tmp_path / "second", "0.0.0", "x86_64-linux-gnu")
    assert first.read_bytes() == second.read_bytes()
    with tarfile.open(first, "r:gz") as archive:
        members = archive.getmembers()
        assert [member.name for member in members] == sorted(member.name for member in members)
        assert all(member.uid == member.gid == member.mtime == 0 for member in members)
    with pytest.raises(ValueError, match="does not match target"):
        package_release.package(binary, tmp_path / "wrong", "0.0.0", "aarch64-linux-gnu")


@pytest.mark.parametrize("workflow", ["ci.yml", "release.yml"])
def test_target_checksum_is_generated_before_every_archive_install(workflow):
    root = Path(__file__).resolve().parents[1]
    jobs = yaml.safe_load((root / ".github/workflows" / workflow).read_text())["jobs"]
    # Find the target installation job by its actual archive invocation.
    installation_jobs = [data for data in jobs.values() if any(
        "scripts/check_install.py --archive" in step.get("run", "") for step in data.get("steps", [])
    )]
    assert len(installation_jobs) == 1
    runs = [step.get("run", "") for step in installation_jobs[0]["steps"]]
    package_index = next(i for i, run in enumerate(runs) if "scripts/package_release.py" in run)
    checksum_index = next(i for i, run in enumerate(runs) if "sha256sum" in run)
    install_index = next(i for i, run in enumerate(runs) if "scripts/check_install.py --archive" in run)
    assert package_index < checksum_index < install_index
    assert "--checksum-file" in runs[install_index]
    assert "--require-postgres" in runs[install_index]
