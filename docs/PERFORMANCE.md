# Performance certification

`scripts/check_performance.py` measures native compilation and the pinned dbt
Core 1.10.5 executable on the same generated 250-model project. The project
contains macros, typed vars and dependency chains. Each of three repetitions
deletes the target for the cold invocation and reuses it for the warm invocation.
Both measurements include process startup; Core can use its partial parse cache
on the warm invocation.

The harness validates complete Manifest v12 and RunResults v6 artifacts and
compares every model's compiled SQL, normalizing whitespace only. Timings cannot
pass when the engines produce different SQL or omit models. The native median
must stay below three seconds and below Core's median for both phases. CI runs
the gate on a ReleaseSafe build and uploads its measured JSON report.

```sh
python -m pip install -r requirements-dev.txt -r requirements-oracle.txt
zig build -Doptimize=ReleaseSafe
python scripts/check_performance.py --report .agent/runs/performance.json
```

The report records versions, model count, repetitions, individual samples,
medians, ratios and the native binary's SHA-256. It contains no local paths.
Use the report to compare like hardware/toolchains; the budget is a regression
gate, not a universal latency guarantee. Native SQL-analysis cache correctness
and invalidation have separate integration gates; a fast compile alone does
not establish that those caches are correct.
