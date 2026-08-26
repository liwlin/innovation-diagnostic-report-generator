# CI Run Summary

Command: `gh run view 32924316381 --repo liwlin/innovation-diagnostic-report-generator --json headSha,conclusion,status,url,jobs,event,createdAt,updatedAt,name`

- Run: <https://github.com/liwlin/innovation-diagnostic-report-generator/actions/runs/32924316381>
- Workflow: CI
- Event: push
- Head SHA: `3a7da7354e4d87090f26c0c179c4cb73c354991b`
- Status: completed
- Conclusion: success
- Created: 2026-08-26T02:52:12Z
- Updated: 2026-08-26T02:53:39Z

Green jobs:

- Python tests, Ruff, and mypy
- Workflow policy
- Node tests
- Secret scan
- Static site, Compose, and script verifiers
- Docker build without push

Boundary: the Docker job used `push: false`; it did not publish a GHCR image digest.
