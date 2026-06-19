#!/usr/bin/env python3
"""Generate a static map of Zig native test declarations by source module."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def count_native_tests(text: str) -> int:
    count = 0
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("//"):
            continue
        if stripped.startswith('test "') or stripped.startswith("test {"):
            count += 1
    return count


def count_non_comment_lines(text: str) -> int:
    return sum(
        1
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("//")
    )


def build_report(source_root: Path) -> dict[str, object]:
    rows = []
    total_tests = 0
    total_lines = 0
    for path in sorted(source_root.rglob("*.zig")):
        text = path.read_text()
        tests = count_native_tests(text)
        lines = count_non_comment_lines(text)
        total_tests += tests
        total_lines += lines
        rows.append(
            {
                "path": path.as_posix(),
                "native_tests": tests,
                "non_comment_lines": lines,
            }
        )

    return {
        "kind": "native_zig_test_coverage_map",
        "description": (
            "Static map of native Zig test declarations by source module. "
            "This is not line coverage."
        ),
        "totals": {
            "native_tests": total_tests,
            "non_comment_lines": total_lines,
            "source_files": len(rows),
        },
        "files": rows,
    }


def markdown_report(report: dict[str, object]) -> str:
    totals = report["totals"]
    rows = report["files"]
    assert isinstance(totals, dict)
    assert isinstance(rows, list)

    lines = [
        "# Native Zig Test Coverage Map",
        "",
        "Static map of native Zig `test` declarations by source module. This is not line coverage.",
        "",
        f"- Source files: {totals['source_files']}",
        f"- Native test declarations: {totals['native_tests']}",
        f"- Non-comment source lines: {totals['non_comment_lines']}",
        "",
        "| Module | Native tests | Non-comment lines |",
        "| --- | ---: | ---: |",
    ]
    for row in rows:
        assert isinstance(row, dict)
        lines.append(
            f"| `{row['path']}` | {row['native_tests']} | {row['non_comment_lines']} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", type=Path, default=Path("src"))
    parser.add_argument("--out", type=Path, default=Path("reports/coverage"))
    args = parser.parse_args()

    report = build_report(args.src)
    markdown = markdown_report(report)
    total_tests = report["totals"]["native_tests"]  # type: ignore[index]

    if total_tests == 0:
        raise SystemExit(
            "native Zig coverage map found 0 test declarations; refusing to publish"
        )
    if "\\n" in markdown:
        raise SystemExit("native Zig coverage map contains literal newline escapes")

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "native-zig-test-map.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    (args.out / "native-zig-test-map.md").write_text(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
