# Native datetime parsing compatibility

The native `datetime_strptime.zig` parser implements the directive grammar and
calendar resolution observed in CPython 3.12.14's
[`Lib/_strptime.py`](https://github.com/python/cpython/blob/v3.12.14/Lib/_strptime.py).
The accompanying license preserves CPython's license and historical notices.
The product does not execute Python or load this reference implementation.

The week-date separator resolution in `datetime_parse.zig` also follows the
CPython 3.12.14 datetime ISO parser, including ambiguous numeric separators.
The same CPython license and historical notices apply to this native helper.

Locale names and composite formats come from the native C library. Unicode
decimal digit ranges use Unicode 15.0.0, matching Python 3.12; the Unicode
license is retained in `vendor/unicode/LICENSE`. CLI compatibility fixtures use
the installed, pinned dbt Core oracle and both initial native adapters.
