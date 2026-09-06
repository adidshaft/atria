# Security Policy

## Supported Versions

`main` is the stable default branch. Day-to-day development lands on `dev`
and is integrated into `main` through a reviewed pull request. Security reports
should identify the affected commit or release branch.

## Reporting a Vulnerability

Do not open public issues for vulnerabilities that expose private health data, device identifiers, signing credentials, or local files.

Report security concerns to [adidshaft](https://x.com/adidshaft). Include:

- affected commit or version,
- reproduction steps,
- expected impact,
- whether logs or evidence files contain private health data.

## Data Handling

Atria is designed for local use. Logs and evidence files can still contain personal data such as timestamps, heart-rate samples, device names, workout periods, and sleep periods. Redact before sharing.
