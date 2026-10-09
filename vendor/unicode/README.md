# Unicode data provenance

`src/project/unicode_case_data.zig` contains Unicode 15.0.0 case mappings and
derived `Cased` / `Case_Ignorable` properties. Full case mappings and Python's
Unicode whitespace behavior are generated using Python 3.12's Unicode 15.0.0
database. Python is used only to generate checked-in developer assets; product
lookups and case conversion run in native Zig.

`scripts/generate_unicode_case.py` verifies the Unicode version and the SHA-256
of Unicode's `DerivedCoreProperties.txt` before generating deterministic tables.
The Unicode data file is retrieved from the Unicode Consortium's unicodetools
repository at `unicodetools/data/ucd/15.0.0/DerivedCoreProperties.txt`.

Source SHA-256:
`d367290bc0867e6b484c68370530bdd1a08b6b32404601b8c7accaf83e05628d`.

The Unicode license is reproduced in `LICENSE`. The same license covers the
Unicode category ranges in `src/project/unicode_repr.zig`.
