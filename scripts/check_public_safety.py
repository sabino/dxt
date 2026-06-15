from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {
    ".git",
    ".pytest_cache",
    ".zig-cache",
    "__pycache__",
    ".agent/runs",
    ".venv",
    "build",
    "dist",
    "target",
    "logs",
    "dbt_packages",
    "zig-out",
}
TEXT_SUFFIXES = {
    ".cfg",
    ".csv",
    ".ini",
    ".jinja",
    ".jinja2",
    ".json",
    ".md",
    ".py",
    ".sql",
    ".toml",
    ".txt",
    ".zig",
    ".zon",
    ".yml",
    ".yaml",
}


PATTERNS = {
    "local home path": re.compile("/home/" + "sabino"),
    "local media path": re.compile("/media/" + "sabino"),
    "local mount name": re.compile("SABINO" + "_EXT4"),
    "github token": re.compile(r"(?:gh[oprstu]_|github" + r"_pat_)" + r"[A-Za-z0-9_]+"),
    "openai token": re.compile(r"sk-(?:proj-)?" + r"[A-Za-z0-9_-]{20,}"),
    "aws access key": re.compile("AKIA" + r"[0-9A-Z]{16}"),
    "private key": re.compile("BEGIN " + r"(RSA|OPENSSH|EC|PRIVATE) KEY"),
}


def should_skip(path: Path) -> bool:
    relative = path.relative_to(ROOT)
    parts = relative.parts
    for skip in SKIP_DIRS:
        skip_parts = tuple(skip.split("/"))
        if parts[: len(skip_parts)] == skip_parts:
            return True
    return False


def is_text_candidate(path: Path) -> bool:
    if path.name in {"AGENTS.md", "PLAN.md", "README.md", "SECURITY.md", ".env.example"}:
        return True
    return path.suffix in TEXT_SUFFIXES


def main() -> int:
    findings: list[str] = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or should_skip(path) or not is_text_candidate(path):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                rel = path.relative_to(ROOT)
                findings.append(f"{rel}:{line}: {label}")

    if findings:
        print("Public-safety scan failed:")
        print("\n".join(findings))
        return 1

    print("Public-safety scan passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
