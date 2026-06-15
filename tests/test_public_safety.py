from __future__ import annotations

import importlib.util
from pathlib import Path


SAFETY_PATH = Path(__file__).resolve().parents[1] / "scripts" / "check_public_safety.py"
SPEC = importlib.util.spec_from_file_location("check_public_safety", SAFETY_PATH)
assert SPEC is not None
assert SPEC.loader is not None
safety = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(safety)


def test_text_candidates_include_dbt_files():
    assert safety.is_text_candidate(safety.ROOT / "models" / "orders.sql")
    assert safety.is_text_candidate(safety.ROOT / "seeds" / "orders.csv")
    assert safety.is_text_candidate(safety.ROOT / ".env.example")


def test_secret_patterns_cover_common_token_prefixes():
    samples = [
        ("github token", "ghp_" + "a" * 32),
        ("github token", "github_pat_" + "a" * 32),
        ("github token", "ghs_" + "a" * 32),
        ("openai token", "sk-proj-" + "a" * 32),
        ("openai token", "sk-" + "a" * 32),
    ]

    for label, sample in samples:
        assert safety.PATTERNS[label].search(sample)
