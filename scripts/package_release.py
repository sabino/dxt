"""Package a native binary and its public docs/licenses for release validation."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import subprocess
import tarfile
from urllib.parse import quote

from check_release_archive import check_archive, infer_expectation
from release_markdown import file_target, markdown_targets

ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = 'https://github.com/sabino/dxt'
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
    'unicode-names-provenance.json': 'vendor/unicode/names-source.json',
    'pcre2-LICENSE': 'vendor/pcre2/LICENSE',
    'pcre2-UPSTREAM': 'vendor/pcre2/README.md',
    'pcre2-provenance.json': 'vendor/pcre2/SOURCE.json',
    'tree-sitter-LICENSE': 'vendor/tree-sitter/LICENSE',
    'tree-sitter-provenance.json': 'vendor/tree-sitter/provenance.json',
    'tree-sitter-unicode-LICENSE': 'vendor/tree-sitter/src/unicode/LICENSE',
    'tree-sitter-python-LICENSE': 'vendor/tree-sitter-python/LICENSE',
    'tree-sitter-python-provenance.json': 'vendor/tree-sitter-python/provenance.json',
    'pytz-LICENSE': 'vendor/pytz/LICENSE.txt',
    'pytz-provenance.json': 'vendor/pytz/provenance.json',
    'cpython-strptime-LICENSE': 'vendor/cpython-strptime/LICENSE.txt',
    'cpython-strptime-UPSTREAM': 'vendor/cpython-strptime/README.md',
    **{f'{package}-LICENSE': f'vendor/dbt-includes/{package}/LICENSE'
       for package in ['dbt', 'dbt_duckdb', 'dbt_postgres']},
}


def source_revision(revision=None):
    """Pin to the checked-out commit, including shallow CI merge checkouts."""
    if revision is not None and not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', revision):
        raise ValueError('source revision must be a full immutable commit hash')
    try:
        result = subprocess.run(['git', 'rev-parse', '--verify', f'{revision or "HEAD"}^{{commit}}'],
                                cwd=ROOT, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ValueError('cannot resolve the release source commit') from exc
    resolved = result.stdout.strip()
    if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', resolved) or (revision and resolved != revision):
        raise ValueError('source revision did not resolve to the exact requested commit')
    return resolved


def source_tree(revision):
    result = subprocess.run(['git', 'ls-tree', '-rzt', '--full-tree', revision],
                            cwd=ROOT, check=True, capture_output=True)
    entries = {'.': ('tree', revision)}
    for entry in result.stdout.split(b'\0'):
        if entry:
            metadata, name = entry.split(b'\t', 1)
            mode, kind, digest = metadata.decode('ascii').split()
            entries[name.decode('utf-8')] = (kind if mode != '120000' else 'symlink', digest)
    return entries


def packaged_paths(sources):
    paths = set(sources)
    for source in sources:
        paths.update(str(parent) for parent in Path(source).parents)
    return paths


def release_markdown(data, document, bundled, revision, tree):
    text = data.decode('utf-8')
    replacements = []
    for destination in markdown_targets(text):
        target = file_target(document, destination.value)
        if target is None:
            continue
        if target.path in bundled:
            continue
        local = ROOT / target.path
        if not local.resolve().is_relative_to(ROOT.resolve()) or not local.exists():
            raise ValueError(f'{document}: unresolved repository target {destination.value!r}')
        kind, digest = tree.get(target.path, ('missing', ''))
        if (kind not in {'blob', 'tree'} or local.is_symlink()
                or (kind == 'blob' and not local.is_file())
                or (kind == 'tree' and not local.is_dir())):
            raise ValueError(f'{document}: target {destination.value!r} is not a file or directory at source {revision}')
        if kind == 'blob':
            content = local.read_bytes()
            hasher = hashlib.sha1 if len(digest) == 40 else hashlib.sha256
            actual = hasher(f'blob {len(content)}\0'.encode('ascii') + content).hexdigest()
            if actual != digest:
                raise ValueError(f'{document}: target {destination.value!r} differs from source {revision}; commit source changes before packaging')
        url = f'{SOURCE_URL}/{"blob" if kind == "blob" else "tree"}/{revision}'
        if target.path != '.':
            url += '/' + quote(target.path, safe='/')
        replacements.append((destination.start, destination.end, url + target.suffix))
    for start, end, value in reversed(replacements):
        text = text[:start] + value + text[end:]
    return text.encode('utf-8')


def package(binary, output, version, target, *, revision=None):
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
    revision = source_revision(revision)
    tree = source_tree(revision)
    bundled = packaged_paths(sources)
    # Validate and transform before creating an archive so bad links cannot leave
    # a partially written release candidate behind.
    markdown = {name: release_markdown(path.read_bytes(), name, bundled, revision, tree)
                for name, path in sources.items() if name.endswith('.md')}
    with archive_path.open('wb') as destination:
        with gzip.GzipFile(fileobj=destination, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as archive:
                for name, path in sorted(sources.items()):
                    info = tarfile.TarInfo(f'{expectation.root_name}/{name}')
                    data = markdown.get(name)
                    info.size = len(data) if data is not None else path.stat().st_size
                    info.mode = 0o755 if name == 'dxt' else 0o644
                    with io.BytesIO(data) if data is not None else path.open('rb') as source:
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
    parser.add_argument('--source-revision', help='Full immutable source commit; defaults to the checked-out HEAD.')
    args = parser.parse_args()
    package(args.dxt.resolve(), args.output_dir, args.version, args.target, revision=args.source_revision)


if __name__ == '__main__':
    main()
