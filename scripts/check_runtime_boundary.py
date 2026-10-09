from __future__ import annotations

import sys
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def runtime_text(text: str) -> str:
    # Python model language metadata is native graph data. Permit precisely its
    # comparison/assignment syntax; interpreter argv strings remain forbidden.
    text = re.sub(r'std\.mem\.eql\(u8,\s*[A-Za-z_][\w.]*\.language,\s*"python"\)',
                  'native_model_language_comparison', text)
    return re.sub(r'\.language\s*=\s*(?:"python"|if\s*\([^;\n]+?\)\s*"python"\s*else\s*"sql")',
                  '.language = native_model_language', text)


def main() -> int:
    findings: list[str] = []

    if (ROOT / "pyproject.toml").exists():
        findings.append("pyproject.toml exists; dxt must not expose a Python product package")

    src_python = sorted((ROOT / "src").rglob("*.py"))
    for path in src_python:
        findings.append(f"{path.relative_to(ROOT)} exists under product source")

    forbidden_runtime_tokens = {
        "std.process.Child": "product runtime must not shell out for parser behavior",
        "ChildProcess": "product runtime must not shell out for parser behavior",
        '"python"': "product runtime must not invoke Python",
        '"python3"': "product runtime must not invoke Python",
    }
    for path in sorted((ROOT / "src").rglob("*.zig")):
        text = runtime_text(path.read_text(encoding="utf-8", errors="ignore"))
        if path.relative_to(ROOT).as_posix() == "src/project/docs_serve.zig":
            # Desktop browser launch is part of docs serve. Permit only this
            # child handle signature; parser/compiler process uses stay banned.
            text = text.replace("fn waitBrowser(io: Io, process: std.process.Child) void {", "")
        for token, reason in forbidden_runtime_tokens.items():
            if token in text:
                findings.append(f"{path.relative_to(ROOT)} contains {token}; {reason}")

    python_product_dirs = [ROOT / "src" / "dxt"]
    for path in python_product_dirs:
        if path.exists():
            findings.append(f"{path.relative_to(ROOT)} exists; product runtime must be Zig")

    if findings:
        print("Runtime boundary check failed:")
        print("\n".join(findings))
        return 1

    print("Runtime boundary check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
