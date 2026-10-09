"""Package a native binary and its public docs/licenses for release validation."""
import argparse
import gzip
import hashlib
from pathlib import Path
import tarfile

from check_release_archive import check_archive, infer_expectation

ROOT = Path(__file__).resolve().parents[1]
NOTICES = {
    'libyaml-LICENSE': 'vendor/libyaml/LICENSE',
    'libyaml-UPSTREAM': 'vendor/libyaml/UPSTREAM',
    'dbt-docs-LICENSE': 'vendor/dbt-docs/LICENSE',
    'dbt-docs-UPSTREAM': 'vendor/dbt-docs/UPSTREAM',
    'libpg_query-LICENSE': 'vendor/libpg_query/LICENSE',
    'libpg_query-THIRD_PARTY_LICENSES.txt': 'vendor/libpg_query/THIRD_PARTY_LICENSES.txt',
    'libpg_query-provenance.json': 'vendor/libpg_query/provenance.json',
    'dbt-includes-provenance.json': 'vendor/dbt-includes/provenance.json',
    'unicode-LICENSE': 'vendor/unicode/LICENSE',
    'unicode-UPSTREAM': 'vendor/unicode/README.md',
    'pcre2-LICENSE': 'vendor/pcre2/LICENSE',
    'pcre2-UPSTREAM': 'vendor/pcre2/README.md',
    'pcre2-provenance.json': 'vendor/pcre2/SOURCE.json',
    'tree-sitter-LICENSE': 'vendor/tree-sitter/LICENSE',
    'tree-sitter-provenance.json': 'vendor/tree-sitter/provenance.json',
    'tree-sitter-unicode-LICENSE': 'vendor/tree-sitter/src/unicode/LICENSE',
    'tree-sitter-python-LICENSE': 'vendor/tree-sitter-python/LICENSE',
    'tree-sitter-python-provenance.json': 'vendor/tree-sitter-python/provenance.json',
    **{f'{package}-LICENSE': f'vendor/dbt-includes/{package}/LICENSE'
       for package in ['dbt', 'dbt_duckdb', 'dbt_postgres']},
}


def package(binary, output, version, target):
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / f'dxt-v{version}-{target}.tar.gz'
    expectation = infer_expectation(archive_path, version, target)
    sources = {'dxt': binary}
    for name in ['README.md', 'CHANGELOG.md', 'SECURITY.md', 'LICENSE']:
        if (ROOT / name).is_file():
            sources[name] = ROOT / name
    sources.update({str(path.relative_to(ROOT)): path for path in (ROOT / 'docs').rglob('*')
                    if path.is_file()})
    sources.update({f'docs/licenses/{name}': ROOT / path for name, path in NOTICES.items()})
    with archive_path.open('wb') as destination:
        with gzip.GzipFile(fileobj=destination, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as archive:
                for name, path in sorted(sources.items()):
                    info = tarfile.TarInfo(f'{expectation.root_name}/{name}')
                    info.size = path.stat().st_size
                    info.mode = 0o755 if name == 'dxt' else 0o644
                    with path.open('rb') as source:
                        archive.addfile(info, source)
    findings = check_archive(archive_path, expectation)
    if findings:
        raise ValueError('\n'.join(findings))
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    print(f'{digest}  {archive_path.name}')
    return archive_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dxt', type=Path, default=ROOT / 'zig-out/bin/dxt')
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'dist')
    parser.add_argument('--version', default='0.0.0')
    parser.add_argument('--target', required=True)
    args = parser.parse_args()
    package(args.dxt.resolve(), args.output_dir, args.version, args.target)


if __name__ == '__main__':
    main()
