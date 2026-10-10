"""Developer-side decoding of dbt-style list command output."""
import json


def json_lines(output):
    return [json.loads(line) for line in output.splitlines() if line.strip()]
