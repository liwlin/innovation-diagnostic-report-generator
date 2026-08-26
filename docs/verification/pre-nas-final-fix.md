# Pre-NAS Final Fix Verification

**Date:** 2026-08-26
**Scope:** pre-NAS final fix wave before DS220+ Task 7.

This file records local/static evidence for the pre-NAS fix wave. It does not replace NAS
hardware proof and does not mark Task 7 complete.

## Red Tests Captured

- `uv run --project server pytest server/tests/test_report_paths.py server/tests/test_records.py server/tests/test_generation_api.py server/tests/test_auth.py server/tests/postgres/test_postgres_security.py -q`
  - Failed for missing pending-delete quarantine primitives, missing commit-failure restore,
    missing finalize-pending behavior, and missing idle-session settings.
- `pwsh -NoProfile -File tests/verify-deploy-scripts.ps1`
  - Failed because `env.example` defaulted to the final report share and mutable
    `current/deploy`, and deploy could reconcile `db` before upgrade backup.
- `pwsh -NoProfile -File tests/verify-workflows.ps1`
  - Failed because root Pages metadata still contained a blank commit placeholder.
- `pwsh -NoProfile -File tests/verify-static-site.ps1`
  - Failed because the root route exposed blank release metadata placeholders.

## Green Verification

| Command | Exit | Result |
| --- | ---: | --- |
| `uv run --project server pytest -q` | 0 | 90 passed, 2 skipped |
| `uv run --project server ruff check` | 0 | All checks passed |
| `uv run --project server mypy server/src/makerseed_app` | 0 | Success, 45 source files checked |
| `node --test tests/js/*.test.js` | 0 | 28 passed |
| `pwsh -NoProfile -File tests/verify-static-site.ps1` | 0 | Static root/runtime passed |
| `pwsh -NoProfile -File tests/verify-compose-security.ps1` | 0 | Hardened two-service Compose policy passed |
| `pwsh -NoProfile -File tests/verify-deploy-scripts.ps1` | 0 | Deploy script safety policy passed |
| `pwsh -NoProfile -File tests/verify-workflows.ps1` | 0 | Workflow policy passed |
| `docker compose -f deploy/compose.yaml config --quiet` with dummy non-secret env | 0 | Compose parsed |
| Workflow YAML parse with `yaml.safe_load` | 0 | Parsed workflow YAML files |
| CI-equivalent secret grep | 0 | No committed secret patterns matched |
| `git diff --check` | 0 | No whitespace errors |

## Boundaries

- Real PostgreSQL grant execution remains skipped locally without
  `MKSEED_POSTGRES_RUNTIME_TEST_URL`.
- No NAS, GHCR, Pages deployment, GitHub settings, tags, or external publication was touched.
- The next DS220+ step must still start from Task 7 isolated hardware proof using
  `REPORT_ROOT_PHASE=isolated` and the project-owned `reports-staging` root.
