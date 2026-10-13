"""Fail closed unless all collected Core cases pass exactly once across shards."""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET

from compatibility_shards import source_identity, validate_shards


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--reports-dir', type=Path, required=True)
    parser.add_argument('--expected-machine', help='Require this actual Linux architecture')
    args = parser.parse_args()
    try:
        count = validate_shards(args.plan, args.reports_dir,
                                source_identity(Path(__file__).resolve().parents[1]),
                                {'system': 'Linux', 'machine': args.expected_machine, 'python': '3.12'}
                                if args.expected_machine else None)
    except (OSError, ValueError, TypeError, KeyError, ET.ParseError) as error:
        parser.exit(1, f'Compatibility shards failed: {error}\n')
    print(f'Compatibility shards passed: {count} cases executed exactly once; '
          'zero failures, errors, skips or xfails')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
