# Security Policy

`dxt` is pre-alpha. Security reports are still welcome.

## Reporting

Please report suspected vulnerabilities privately through GitHub security advisories once the public repository is enabled. Until then, contact the repository owner directly.

Do not include secrets, credentials, production data, or private database connection details in public issues.

## Project Safety Rules

- No secrets in source, tests, docs, examples, logs, generated artifacts, or release packages.
- No real private data in fixtures.
- No committed local absolute paths or private hostnames.
- Runtime credentials must come from profiles, environment variables, or secret providers, not project files.
- Cross-database execution must expose and enforce movement policies before moving sensitive or expensive data.
