"""Generate the native Unicode 15 case/whitespace tables (developer tooling)."""
from __future__ import annotations

import argparse
import hashlib
import json
import unicodedata
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
DATA_URL = "https://raw.githubusercontent.com/unicode-org/unicodetools/main/unicodetools/data/ucd/15.0.0/DerivedCoreProperties.txt"
DATA_SHA256 = "d367290bc0867e6b484c68370530bdd1a08b6b32404601b8c7accaf83e05628d"


def ranges(values):
    result = []
    for value in sorted(values):
        if result and value == result[-1][1] + 1:
            result[-1][1] = value
        else:
            result.append([value, value])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-core-properties", type=Path)
    args = parser.parse_args()
    if unicodedata.unidata_version != "15.0.0":
        raise SystemExit("Generation requires Python with Unicode 15.0.0 (Python 3.12).")
    data = args.derived_core_properties.read_bytes() if args.derived_core_properties else urlopen(DATA_URL, timeout=30).read()
    if hashlib.sha256(data).hexdigest() != DATA_SHA256:
        raise SystemExit("Unexpected Unicode source checksum")
    properties = {"Cased": set(), "Case_Ignorable": set()}
    for line in data.decode().splitlines():
        content = line.split("#", 1)[0].strip()
        if not content:
            continue
        span, prop = (part.strip() for part in content.split(";", 1))
        if prop not in properties:
            continue
        boundaries = span.split("..")
        start, stop = int(boundaries[0], 16), int(boundaries[-1], 16)
        properties[prop].update(range(start, stop + 1))
    output = [
        "//! Generated Unicode 15.0.0 full case mappings and Python whitespace.",
        "//! Regenerate with scripts/generate_unicode_case.py; see vendor/unicode.",
        "pub const Mapping = struct { code: u21, text: []const u8 };",
    ]
    for name in ("lower", "upper", "title", "casefold"):
        output.append(f"pub const {name} = [_]Mapping{{")
        for code in range(0x110000):
            character = chr(code)
            converted = getattr(character, name)()
            if converted != character:
                output.append(f"    .{{ .code = 0x{code:x}, .text = {json.dumps(converted, ensure_ascii=False)} }},")
        output.append("};")
    properties["whitespace"] = {code for code in range(0x110000) if chr(code).isspace()}
    for name, values in properties.items():
        output.append(f"pub const {name.lower()} = [_][2]u21{{")
        output.extend(f"    .{{ 0x{start:x}, 0x{stop:x} }}," for start, stop in ranges(values))
        output.append("};")
    (ROOT / "src/project/unicode_case_data.zig").write_text("\n".join(output) + "\n")


if __name__ == "__main__":
    main()
