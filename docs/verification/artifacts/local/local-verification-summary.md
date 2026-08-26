# Local Verification Summary

Date: 2026-08-26 11:03:11 +08:00
Commit: `3a7da7354e4d87090f26c0c179c4cb73c354991b`

| Command | Exit | Summary |
| --- | ---: | --- |
| `uv run --project server pytest` | 0 | 85 collected; 83 passed, 2 skipped; 24.15s |
| `uv run --project server ruff check` | 0 | All checks passed |
| `uv run --project server mypy server/src/makerseed_app` | 0 | Success; 45 files checked |
| `node --test tests/js/*.test.js` | 0 | 28 passed, 0 failed |
| `pwsh -NoProfile -File tests/verify-static-site.ps1` | 0 | Static runtime available |
| `pwsh -NoProfile -File tests/verify-compose-security.ps1` | 0 | Compose hardening passed |
| `docker compose -f deploy/compose.yaml config --quiet` with dummy non-secret env | 0 | Compose parsed |
| `pwsh -NoProfile -File tests/verify-deploy-scripts.ps1` | 0 | Script guard checks passed |
| `pwsh -NoProfile -File tests/verify-workflows.ps1` | 0 | Workflow policy passed |
| CI-equivalent `git grep` secret scan | 0 | No matches |
| Python YAML parse of `.github/workflows/*.yml` | 0 | Parsed |
| `git diff --check` | 0 | Clean |

Browser E2E was not freshly rerun because this checkout contains a browser flow contract, not a runnable Playwright suite, and no local Playwright runtime was available.
