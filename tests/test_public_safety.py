from __future__ import annotations

import importlib.util
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile


SAFETY_PATH = Path(__file__).resolve().parents[1] / "scripts" / "check_public_safety.py"
SPEC = importlib.util.spec_from_file_location("check_public_safety", SAFETY_PATH)
assert SPEC is not None
assert SPEC.loader is not None
safety = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(safety)

RELEASE_ARCHIVE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "check_release_archive.py"
RELEASE_SPEC = importlib.util.spec_from_file_location("check_release_archive", RELEASE_ARCHIVE_PATH)
assert RELEASE_SPEC is not None
assert RELEASE_SPEC.loader is not None
release_archive = importlib.util.module_from_spec(RELEASE_SPEC)
RELEASE_SPEC.loader.exec_module(release_archive)


def test_text_candidates_include_dbt_files():
    assert safety.is_text_candidate(safety.ROOT / "models" / "orders.sql")
    assert safety.is_text_candidate(safety.ROOT / "seeds" / "orders.csv")
    assert safety.is_text_candidate(safety.ROOT / ".env.example")
    assert safety.is_text_candidate(safety.ROOT / "src" / "main.zig")
    assert safety.is_text_candidate(safety.ROOT / "build.zig.zon")


def test_generated_zig_output_is_skipped():
    assert safety.should_skip(safety.ROOT / "zig-out" / "bin" / "dxt")
    assert safety.should_skip(safety.ROOT / ".zig-cache" / "tmp" / "build")


def test_secret_patterns_cover_common_token_prefixes():
    samples = [
        ("github token", "gh" + "p_" + "a" * 32),
        ("github token", "github" + "_pat_" + "a" * 32),
        ("github token", "gh" + "s_" + "a" * 32),
        ("openai token", "sk-" + "proj-" + "a" * 32),
        ("openai token", "sk" + "-" + "a" * 32),
    ]

    for label, sample in samples:
        assert safety.PATTERNS[label].search(sample)


def test_runtime_boundary_check_passes():
    result = subprocess.run(
        ["python", "scripts/check_runtime_boundary.py"],
        cwd=safety.ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def add_tar_file(archive: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    archive.addfile(info, io.BytesIO(data))


def write_release_archive(path: Path, *, leaked_binary_text: bytes = b""):
    root = "dxt-v0.0.0-x86_64-linux-gnu"
    with tarfile.open(path, "w:gz") as archive:
        for directory in [root, f"{root}/docs"]:
            info = tarfile.TarInfo(directory)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        add_tar_file(archive, f"{root}/dxt", b"binary" + leaked_binary_text, 0o755)
        add_tar_file(archive, f"{root}/README.md", b"# dxt\n")
        add_tar_file(archive, f"{root}/CHANGELOG.md", b"# Changelog\n")
        add_tar_file(archive, f"{root}/SECURITY.md", b"# Security\n")
        add_tar_file(archive, f"{root}/docs/RELEASES.md", b"# Release Process\n")


def test_release_archive_check_accepts_expected_shape(tmp_path):
    archive = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    write_release_archive(archive)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksums = tmp_path / "dxt-v0.0.0-SHA256SUMS.txt"
    checksums.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")

    assert release_archive.main(
        [
            str(archive),
            "--version",
            "0.0.0",
            "--target",
            "x86_64-linux-gnu",
            "--checksum-file",
            str(checksums),
        ]
    ) == 0


def test_release_archive_check_rejects_binary_path_leak(tmp_path):
    archive = tmp_path / "dxt-v0.0.0-x86_64-linux-gnu.tar.gz"
    write_release_archive(archive, leaked_binary_text=b"/home/example/private")

    assert release_archive.main([str(archive), "--version", "0.0.0"]) == 1
