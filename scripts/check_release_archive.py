from __future__ import annotations

import argparse
import hashlib
import posixpath
import re
import struct
import sys
import tarfile
from pathlib import Path
from typing import NamedTuple

from release_markdown import file_target, markdown_targets


VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
TARGET_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ELF_MACHINES = {"x86_64-linux-gnu": 62, "aarch64-linux-gnu": 183}
MACHO_CPUS = {"x86_64-macos": 0x01000007, "aarch64-macos": 0x0100000C}
RELEASE_TARGETS = {*ELF_MACHINES, *MACHO_CPUS}
NATIVE_DRIVER_NOTICES = {
    "docs/licenses/native-drivers/" + name for name in (
        "DUCKDB-LICENSE.txt", "DUCKDB-THIRD-PARTY-NOTICES.txt",
        "POSTGRESQL-LICENSE.txt", "LIBPQ-BUILD-LICENSE.txt",
        "LIBRESSL-LICENSE.txt", "LIBRESSL-BUILD-LICENSE.txt",
        "LIBCQUERY-LICENSE.txt", "README.md",
    )
}

REQUIRED_MEMBERS = {
    "dxt",
    "README.md",
    "CHANGELOG.md",
    "SECURITY.md",
    "docs/RELEASES.md",
    "docs/licenses/libyaml-LICENSE",
    "docs/licenses/libyaml-UPSTREAM",
    "docs/licenses/dbt-docs-LICENSE",
    "docs/licenses/dbt-docs-UPSTREAM",
    "docs/licenses/libpg_query-LICENSE",
    "docs/licenses/libpg_query-THIRD_PARTY_LICENSES.txt",
    "docs/licenses/libpg_query-provenance.json",
    "docs/licenses/dbt-includes-provenance.json",
    "docs/licenses/dbt-LICENSE",
    "docs/licenses/dbt_duckdb-LICENSE",
    "docs/licenses/dbt_postgres-LICENSE",
    "docs/licenses/unicode-LICENSE",
    "docs/licenses/unicode-UPSTREAM",
    "docs/licenses/unicode-names-provenance.json",
    "docs/licenses/pcre2-LICENSE",
    "docs/licenses/pcre2-UPSTREAM",
    "docs/licenses/pcre2-provenance.json",
    "docs/licenses/tree-sitter-LICENSE",
    "docs/licenses/tree-sitter-provenance.json",
    "docs/licenses/tree-sitter-unicode-LICENSE",
    "docs/licenses/tree-sitter-python-LICENSE",
    "docs/licenses/tree-sitter-python-provenance.json",
    "docs/licenses/pytz-LICENSE",
    "docs/licenses/pytz-provenance.json",
    "docs/licenses/cpython-strptime-LICENSE",
    "docs/licenses/cpython-strptime-UPSTREAM",
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
    if inferred_target not in RELEASE_TARGETS:
        raise ValueError(f"{path}: unsupported release target {inferred_target!r}")

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


def check_elf(data: bytes, target: str, context: str) -> list[str]:
    """Check the executable header against the declared Linux release target."""
    if len(data) < 64:
        return [f"{context}: dxt binary has a truncated ELF64 header"]
    if data[:4] != b"\x7fELF":
        return [f"{context}: dxt binary is not an ELF executable"]
    if data[4] != 2:
        return [f"{context}: dxt binary must use the ELF64 class"]
    if data[5] != 1:
        return [f"{context}: dxt binary must use little-endian ELF encoding"]
    header = struct.unpack("<16sHHIQQQIHHHHHH", data[:64])
    _, file_type, machine, version, _, _, _, _, header_size, _, _, _, _, _ = header
    findings = []
    if data[6] != 1 or version != 1:
        findings.append(f"{context}: dxt binary has an invalid ELF version")
    if file_type not in {2, 3}:  # ET_EXEC or ET_DYN (position-independent executable)
        findings.append(f"{context}: dxt binary is not an ELF executable or PIE")
    if header_size != 64:
        findings.append(f"{context}: dxt binary has an invalid ELF64 header size")
    expected_machine = ELF_MACHINES.get(target)
    if expected_machine is None or machine != expected_machine:
        findings.append(f"{context}: ELF machine {machine} does not match target {target}")
    return findings


def check_macho(data: bytes, target: str, context: str) -> list[str]:
    """Require a thin 64-bit executable and only the bundled build's OS libraries."""
    if len(data) < 32:
        return [f"{context}: dxt binary has a truncated Mach-O64 header"]
    magic, cpu, _, file_type, count, commands_size, _, _ = struct.unpack("<8I", data[:32])
    if magic != 0xFEEDFACF:
        return [f"{context}: dxt binary is not a little-endian Mach-O64 executable"]
    findings = []
    if cpu != MACHO_CPUS.get(target):
        findings.append(f"{context}: Mach-O CPU {cpu} does not match target {target}")
    if file_type != 2:  # MH_EXECUTE
        findings.append(f"{context}: dxt binary is not a Mach-O executable")
    end = 32 + commands_size
    if end > len(data) or count > commands_size // 8:
        return findings + [f"{context}: truncated Mach-O load commands"]
    position = 32
    libraries = set()
    for _ in range(count):
        if position + 8 > end:
            return findings + [f"{context}: truncated Mach-O load command"]
        command, size = struct.unpack_from("<2I", data, position)
        if size < 8 or size % 8 or position + size > end:
            return findings + [f"{context}: invalid Mach-O load command size"]
        if command in {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}:
            if size < 24:
                return findings + [f"{context}: truncated Mach-O library command"]
            offset = struct.unpack_from("<I", data, position + 8)[0]
            if offset < 24 or offset >= size:
                return findings + [f"{context}: invalid Mach-O library name offset"]
            name = data[position + offset:position + size]
            if b"\0" not in name:
                return findings + [f"{context}: unterminated Mach-O library name"]
            try:
                library = name.split(b"\0", 1)[0].decode("utf-8")
            except UnicodeError:
                return findings + [f"{context}: invalid Mach-O library name"]
            libraries.add(library)
            if library not in {"/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib"}:
                findings.append(f"{context}: external runtime library {library!r} in bundled macOS binary")
        position += size
    if position != end:
        findings.append(f"{context}: inconsistent Mach-O load command count")
    if "/usr/lib/libSystem.B.dylib" not in libraries:
        findings.append(f"{context}: Mach-O executable is missing its system runtime")
    return findings


def check_archive(path: Path, expectation: ArchiveExpectation) -> list[str]:
    findings: list[str] = []
    seen: set[str] = set()
    files: set[str] = set()
    markdown: dict[str, bytes] = {}
    required = REQUIRED_MEMBERS | (NATIVE_DRIVER_NOTICES if expectation.target in MACHO_CPUS else set())
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

                if relative_name in seen:
                    findings.append(f"{path}: duplicate member {normalized!r}")
                seen.add(relative_name)

                path_finding = check_member_path(relative_name)
                if path_finding is not None:
                    findings.append(f"{path}: {path_finding}")

                if not (member.isdir() or member.isfile()):
                    findings.append(f"{path}: member {normalized!r} is not a regular file or directory")
                    continue

                if relative_name == "dxt":
                    if not member.isfile():
                        findings.append(f"{path}: dxt binary is not a regular file")
                    elif member.mode & 0o111 == 0:
                        findings.append(f"{path}: dxt binary is not executable in archive metadata")
                elif relative_name in required and not member.isfile():
                    findings.append(f"{path}: required member {relative_name!r} is not a regular file")

                if member.isfile():
                    files.add(relative_name)
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        findings.append(f"{path}: could not read {normalized!r}")
                        continue
                    data = extracted.read()
                    if relative_name.endswith('.md'):
                        markdown[relative_name] = data
                    findings.extend(scan_bytes(data, f"{path}:{relative_name}"))
                    if relative_name == "dxt":
                        check_binary = check_macho if expectation.target in MACHO_CPUS else check_elf
                        findings.extend(check_binary(data, expectation.target, f"{path}:dxt"))
    except (tarfile.TarError, OSError, EOFError) as exc:
        return [f"{path}: could not read archive: {exc}"]

    for member in sorted(required - seen):
        findings.append(f"{path}: missing required member {expectation.root_name}/{member}")

    bundled = files | {str(parent) for name in files for parent in Path(name).parents}
    for document, data in sorted(markdown.items()):
        try:
            for destination in markdown_targets(data.decode('utf-8')):
                target = file_target(document, destination.value)
                if target is not None and target.path not in bundled:
                    findings.append(f'{path}:{document}: unresolved relative Markdown target {destination.value!r}')
        except (UnicodeError, ValueError) as exc:
            findings.append(f'{path}:{document}: invalid Markdown link: {exc}')

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


def check_checksums(
    checksum_file: Path, archives: list[Path], *, allow_other_archives: bool = False
) -> list[str]:
    findings: list[str] = []
    try:
        checksums = parse_checksum_file(checksum_file)
    except (OSError, ValueError) as exc:
        return [str(exc)]

    expected_names = {archive.name for archive in archives}
    checksum_names = set(checksums)
    for missing in sorted(expected_names - checksum_names):
        findings.append(f"{checksum_file}: missing checksum for {missing}")
    if not allow_other_archives:
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
    parser.add_argument("--require-all-targets", action="store_true",
                        help="Require exactly one archive for every release target before publication")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.target is not None and len(args.archives) != 1:
        parser.error("--target can only be used with one archive")

    findings: list[str] = []
    archives = [archive.resolve() for archive in args.archives]
    targets = []
    for archive in archives:
        if not archive.is_file():
            findings.append(f"{archive}: archive does not exist")
            continue
        try:
            expectation = infer_expectation(archive, args.version, args.target)
        except ValueError as exc:
            findings.append(str(exc))
            continue
        targets.append(expectation.target)
        findings.extend(check_archive(archive, expectation))

    if args.require_all_targets and (set(targets) != RELEASE_TARGETS or len(targets) != len(RELEASE_TARGETS)):
        findings.append("publication requires exactly one archive for every release target")

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
