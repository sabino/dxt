# Native regular expression engine

This is the PCRE2 10.44 UTF-8 library, pinned to upstream revision
`6ae58beca071f13ccfed31d03b3f479ab520639b` in the PCRE2Project/pcre2 repository.
Its Unicode property tables use Unicode 15.0.0, matching the pinned Core oracle.

The source files and headers are copied unchanged. `config.h`, `pcre2.h` and
`pcre2_chartables.c` are the upstream generic header and default character-table
templates under their build names. `SOURCE.json` records hashes. `sources.zig`
lists the static library's source files.

The product statically links the 8-bit Unicode engine, without JIT or external
runtime dependencies. Zig owns Python-compatible argument binding, pattern
normalization, match values, capture groups, substitutions and iteration. The
license is reproduced in `LICENSE` and must accompany binary distributions.
