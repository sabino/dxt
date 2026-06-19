from __future__ import annotations

import argparse
import hashlib
import posixpath
import re
import sys
import tarfile
from pathlib import Path
from typing import NamedTuple


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
TARGET_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

REQUIRED_MEMBERS = {
    "dxt",
    "README.md",
    "CHANGELOG.md",
    "SECURITY.md",
    "docs/RELEASES.md",
}

ALLOWED_TOP_LEVEL_FILES = {
    "dxt",
    "README.md",
    "CHANGELOG.md",
    "SECURITY.md",
    "LICENSE",
}

DENYLISTED_COMPONENTS = {
    ".agent",
    ".git",
    ".github",
    ".pytest_cache",
    ".zig-cache",
    ".venv",
    "__pycache__",
    "build",
    "dbt_packages",
    "dist",
    "logs",
    "target",
    "zig-out",
}

BYTE_PATTERNS = {
    "absolute home path": re.compile(rb"/home/"),
    "absolute media path": re.compile(rb"/media/"),
    "local mount name": re.compile(b"SABINO" + b"_EXT4"),
    "github token": re.compile(rb"(?:gh[oprstu]_|github_pat_)[A-Za-z0-9_]{20,}"),
    "openai token": re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{20,}"),
    "aws access key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "private key": re.compile(rb"BEGIN (?:RSA|OPENSSH|EC|PRIVATE) KEY"),
}


class ArchiveExpectation(NamedTuple):
    version: str
    target: str
    root_name: str


def archive_name_without_tar_gz(path: Path) -> str:
    name = path.name
    if not name.endswith(".tar.gz"):
        raise ValueError(f"{path}: release archives must end with .tar.gz")
    return name[: -len(".tar.gz")]


def infer_expectation(path: Path, version: str, target: str | None) -> ArchiveExpectation:
    if not VERSION_RE.match(version):
        raise ValueError(f"{path}: expected version must look like 0.1.0 or 0.1.0-alpha.1")

    root_name = archive_name_without_tar_gz(path)
    prefix = f"dxt-v{version}-"
    if not root_name.startswith(prefix):
        raise ValueError(f"{path}: archive name must start with {prefix}")

    inferred_target = root_name[len(prefix) :]
    if not TARGET_RE.match(inferred_target):
        raise ValueError(f"{path}: archive target {inferred_target!r} is not valid")
    if target is not None and target != inferred_target:
        raise ValueError(f"{path}: archive target {inferred_target} does not match expected {target}")

    return ArchiveExpectation(
        version=version,
        target=target or inferred_target,
        root_name=root_name,
    )


def normalized_member_name(name: str) -> str | None:
    if name.startswith("/") or name == "":
        return None
    normalized = posixpath.normpath(name)
    if normalized == "." or normalized.startswith("../") or normalized == "..":
        return None
    if normalized != name.rstrip("/"):
        return None
    return normalized


def strip_root(member_name: str, root_name: str) -> str | None:
    if member_name == root_name:
        return ""
    prefix = root_name + "/"
    if not member_name.startswith(prefix):
        return None
    return member_name[len(prefix) :]


def member_is_allowed(relative_name: str) -> bool:
    if relative_name == "":
        return True
    if relative_name in ALLOWED_TOP_LEVEL_FILES:
        return True
    if relative_name == "docs" or relative_name.startswith("docs/"):
        return True
    return False


def check_member_path(relative_name: str) -> str | None:
    parts = tuple(part for part in relative_name.split("/") if part)
    if any(part in DENYLISTED_COMPONENTS for part in parts):
        return f"contains denylisted path component {relative_name}"
    if not member_is_allowed(relative_name):
        return f"contains unexpected member {relative_name}"
    return None


def scan_bytes(data: bytes, context: str) -> list[str]:
    findings: list[str] = []
    for label, pattern in BYTE_PATTERNS.items():
        if pattern.search(data):
            findings.append(f"{context}: {label}")
    return findings


def check_archive(path: Path, expectation: ArchiveExpectation) -> list[str]:
    findings: list[str] = []
    seen: set[str] = set()
    try:
        with tarfile.open(path, "r:gz") as archive:
            members = archive.getmembers()
            if not members:
                return [f"{path}: archive is empty"]

            for member in members:
                normalized = normalized_member_name(member.name)
                if normalized is None:
                    findings.append(f"{path}: unsafe member path {member.name!r}")
                    continue

                relative_name = strip_root(normalized, expectation.root_name)
                if relative_name is None:
                    findings.append(f"{path}: member {normalized!r} is outside expected root {expectation.root_name!r}")
                    continue

                seen.add(relative_name)

                path_finding = check_member_path(relative_name)
                if path_finding is not None:
                    findings.append(f"{path}: {path_finding}")

                if not (member.isdir() or member.isfile()):
                    findings.append(f"{path}: member {normalized!r} is not a regular file or directory")
                    continue

                if relative_name == "dxt" and member.isfile() and member.mode & 0o111 == 0:
                    findings.append(f"{path}: dxt binary is not executable in archive metadata")

                if member.isfile():
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        findings.append(f"{path}: could not read {normalized!r}")
                        continue
                    findings.extend(scan_bytes(extracted.read(), f"{path}:{relative_name}"))
    except (tarfile.TarError, OSError) as exc:
        return [f"{path}: could not read archive: {exc}"]

    for member in sorted(REQUIRED_MEMBERS - seen):
        findings.append(f"{path}: missing required member {expectation.root_name}/{member}")

    return findings


def parse_checksum_file(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ValueError(f"{path}:{line_number}: expected '<sha256>  <filename>'")
        digest, filename = parts
        filename = filename.lstrip("*")
        if not SHA256_RE.match(digest):
            raise ValueError(f"{path}:{line_number}: invalid sha256 digest")
        if "/" in filename or "\\" in filename or filename in {"", ".", ".."}:
            raise ValueError(f"{path}:{line_number}: checksum filename must be a basename")
        if filename in checksums:
            raise ValueError(f"{path}:{line_number}: duplicate checksum for {filename}")
        checksums[filename] = digest
    return checksums


def check_checksums(checksum_file: Path, archives: list[Path]) -> list[str]:
    findings: list[str] = []
    try:
        checksums = parse_checksum_file(checksum_file)
    except (OSError, ValueError) as exc:
        return [str(exc)]

    expected_names = {archive.name for archive in archives}
    checksum_names = set(checksums)
    for missing in sorted(expected_names - checksum_names):
        findings.append(f"{checksum_file}: missing checksum for {missing}")
    for extra in sorted(checksum_names - expected_names):
        findings.append(f"{checksum_file}: checksum references unexpected file {extra}")

    for archive in archives:
        if archive.name not in checksums:
            continue
        try:
            actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        except OSError as exc:
            findings.append(f"{archive}: could not read archive for checksum verification: {exc}")
            continue
        expected = checksums[archive.name]
        if actual != expected:
            findings.append(f"{checksum_file}: checksum mismatch for {archive.name}")

    return findings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate dxt release archives before upload.")
    parser.add_argument("archives", nargs="+", type=Path, help="Release .tar.gz archives to inspect.")
    parser.add_argument("--version", required=True, help="Expected version without the leading v.")
    parser.add_argument("--target", help="Expected target triple. Use only when checking one archive.")
    parser.add_argument("--checksum-file", type=Path, help="Optional SHA256SUMS file to verify.")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.target is not None and len(args.archives) != 1:
        parser.error("--target can only be used with one archive")

    findings: list[str] = []
    archives = [archive.resolve() for archive in args.archives]
    for archive in archives:
        if not archive.is_file():
            findings.append(f"{archive}: archive does not exist")
            continue
        try:
            expectation = infer_expectation(archive, args.version, args.target)
        except ValueError as exc:
            findings.append(str(exc))
            continue
        findings.extend(check_archive(archive, expectation))

    if args.checksum_file is not None:
        findings.extend(check_checksums(args.checksum_file.resolve(), archives))

    if findings:
        print("Release archive safety check failed:")
        print("\n".join(findings))
        return 1

    print("Release archive safety check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
