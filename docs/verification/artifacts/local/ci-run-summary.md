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

## Task 7 first-install fix round 5 local verification

Timestamp: 2026-08-26T17:09:52+08:00

Scope: local deploy-script and first-install verification only. No NAS, push, tag, GHCR, Pages, or external deployment was touched.

RED:

- `wsl -e sh -lc 'cd /mnt/f/Git/科创诊断报告生成器优化/.worktrees/nas-centralized-app && MKSEED_EPHEMERAL_VOLUME1_TEST=1 sh tests/linux/verify-first-install-admin.sh'` returned exit 1 with `FAIL: other-file current.env.sha256 was accepted`.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File ./tests/verify-deploy-scripts.ps1` returned exit 1 with `Deploy must require canonical current.env.sha256 syntax before taking the deployment lock.`

GREEN:

- `uv run --project server pytest` returned exit 0: 90 passed, 2 skipped.
- `uv run --project server ruff check` returned exit 0: all checks passed.
- `uv run --project server mypy server/src/makerseed_app` returned exit 0: no issues in 45 source files.
- `node --test` returned exit 0: 28 passed.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File ./tests/verify-static-site.ps1` returned exit 0.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File ./tests/verify-compose-security.ps1` returned exit 0.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File ./tests/verify-deploy-scripts.ps1` returned exit 0.
- `pwsh -NoProfile -ExecutionPolicy Bypass -File ./tests/verify-workflows.ps1` returned exit 0.
- `wsl -e sh -lc 'cd /mnt/f/Git/科创诊断报告生成器优化/.worktrees/nas-centralized-app && MKSEED_EPHEMERAL_VOLUME1_TEST=1 sh tests/linux/verify-bootstrap-preflight.sh'` returned exit 0.
- `wsl -e sh -lc 'cd /mnt/f/Git/科创诊断报告生成器优化/.worktrees/nas-centralized-app && MKSEED_EPHEMERAL_VOLUME1_TEST=1 sh tests/linux/verify-first-install-admin.sh'` returned exit 0.

Note: Windows PowerShell 5.1 misread the UTF-8 Chinese literal in `tests/verify-deploy-scripts.ps1`; `pwsh` was used for the PowerShell verification path.
