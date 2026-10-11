#!/usr/bin/env python3
"""Developer-only deterministic extraction of pinned pytz/IANA transition tables.

The product embeds this data and evaluates transitions in native Zig. No Python
or host timezone database is consulted at runtime. Regenerate with the pinned
requirements-oracle.txt environment; --check verifies reproducibility.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import struct
from datetime import datetime
from importlib.metadata import distribution
from pathlib import Path
import pytz

VERSION = "2026.5"
IANA_VERSION = "2026e"
ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "vendor/pytz"


def generate():
    assert pytz.__version__ == VERSION
    assert pytz.OLSON_VERSION == IANA_VERSION
    pool = bytearray()
    strings = {}
    def string(value):
        if value not in strings:
            strings[value] = len(pool)
            pool.extend(value.encode("utf-8") + b"\0")
        return strings[value]
    epoch = datetime(1970, 1, 1)
    zones, transitions = [], []
    for name in pytz.all_timezones:
        zone = pytz.timezone(name)
        dynamic = hasattr(zone, "_utc_transition_times")
        infos = zone._transition_info if dynamic else [(zone._utcoffset, getattr(zone, "_dst", None), zone._tzname)]
        times = zone._utc_transition_times if dynamic else [datetime.min]
        start = len(transitions)
        for stamp, (offset, dst, abbreviation) in zip(times, infos):
            seconds = int((stamp - epoch).total_seconds())
            transitions.append(struct.pack("<qiiI", seconds, int(offset.total_seconds()), int(dst.total_seconds()) if dst else 0, string(abbreviation)))
        zones.append(struct.pack("<IIII", string(name), start, len(infos), int(dynamic)))
    countries, country_zones = [], []
    for code, name in sorted(pytz.country_names.items()):
        names = pytz.country_timezones.get(code, [])
        start = len(country_zones)
        country_zones.extend(struct.pack("<I", string(zone)) for zone in names)
        countries.append(struct.pack("<IIII", string(code), string(name), start, len(names)))
    common = [struct.pack("<I", string(name)) for name in pytz.common_timezones]
    header = b"DXTZ0001" + struct.pack("<IIIIII", len(zones), len(transitions), len(countries), len(country_zones), len(common), len(pool))
    payload = header + b"".join(zones + transitions + countries + country_zones + common) + pool
    metadata = {
        "upstream": "https://pypi.org/project/pytz/2026.5/",
        "iana_upstream": "https://data.iana.org/time-zones/releases/tzdata2026e.tar.gz",
        "pytz_version": VERSION,
        "iana_version": IANA_VERSION,
        "generator": "scripts/generate_pytz_tables.py",
        "format": "DXTZ0001: little-endian zone and transition records; NUL-terminated UTF-8 string pool",
        "semantics": "pytz transition instants, minute rounding, DST deltas, aliases, common zones and country tables",
        "zone_count": len(zones), "transition_count": len(transitions),
        "country_count": len(countries), "common_zone_count": len(common),
        "tables_sha256": hashlib.sha256(payload).hexdigest(),
        "license": "MIT for pytz; IANA timezone data is public domain",
    }
    license_text = distribution("pytz").locate_file(f"pytz-{VERSION}.dist-info/LICENSE.txt").read_text()
    return {"zoneinfo.bin": payload, "provenance.json": (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode(), "LICENSE.txt": license_text.encode()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name, payload in generate().items():
        target = TARGET / name
        if args.check:
            assert target.read_bytes() == payload, f"Regenerate {target.relative_to(ROOT)}"
        else:
            TARGET.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
    print("Pinned pytz/IANA tables are reproducible." if args.check else "Generated pinned pytz/IANA tables.")

if __name__ == "__main__":
    main()
