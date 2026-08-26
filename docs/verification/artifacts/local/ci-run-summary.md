# CI and Release Run Summary

Final head CI:

- Command: `gh run view 32925836784 --repo liwlin/innovation-diagnostic-report-generator --json headSha,conclusion,status,url,jobs,event,createdAt,updatedAt,name`
- Run: <https://github.com/liwlin/innovation-diagnostic-report-generator/actions/runs/32925836784>
- Workflow: CI
- Event: push
- Head SHA: `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`
- Status: completed
- Conclusion: success
- Created: 2026-08-26T03:16:34Z
- Updated: 2026-08-26T03:17:58Z

Green CI jobs:

- Static site, Compose, and script verifiers
- Workflow policy
- Secret scan
- Node tests
- Python tests, Ruff, and mypy
- Docker build without push

Release run:

- Command: `gh run view 32925993328 --repo liwlin/innovation-diagnostic-report-generator --json headSha,conclusion,status,url,jobs,event,createdAt,updatedAt,name`
- Run: <https://github.com/liwlin/innovation-diagnostic-report-generator/actions/runs/32925993328>
- Workflow: Release
- Event: push
- Head SHA: `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`
- Status: completed
- Conclusion: success
- Created: 2026-08-26T03:19:06Z
- Updated: 2026-08-26T03:22:08Z

Green release jobs:

- Re-verify release commit
- Publish allowlisted Pages artifact
- Publish GHCR image, SBOM, provenance, and vulnerability gate

Tag proof:

- `git ls-remote --tags origin "refs/tags/v0.1.0^{}"` returned `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`.

Boundary: final CI still includes a Docker build without push, while the separate release run provides the published GHCR/SBOM/provenance evidence.