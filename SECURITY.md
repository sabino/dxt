# Security Policy

`dxt` is a prerelease and is **not production ready**. Security reports are
welcome for the native runtime, developer tooling and release artifacts.

## Reporting

Report suspected vulnerabilities privately through
[GitHub security advisories](https://github.com/sabino/dxt/security/advisories/new).
If private reporting is unavailable, contact the repository owner directly.

Do not include secrets, credentials, production data, or private database connection details in public issues.

## Project Safety Rules

- No secrets in source, tests, docs, examples, logs, generated artifacts, or release packages.
- No real private data in fixtures.
- No committed local absolute paths or private hostnames.
- Runtime credentials must come from profiles, environment variables, or secret providers, not project files.
- Cross-database execution must expose and enforce movement policies before moving sensitive or expensive data.
