# Local Verification Summary

Date: 2026-08-26 12:00:16 +08:00
Released candidate commit: `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`
Release tag: `v0.1.0`

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
| CI-equivalent `git grep -n -I -E '(AKIA[0-9A-Z]{16}|-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----|ghp_[A-Za-z0-9_]{36,}|sk-[A-Za-z0-9]{20,})' -- . ':!server/uv.lock' ':!vendor/*'` | 0 | No matches |
| `python -c "import yaml, pathlib; [yaml.safe_load(p.read_text(encoding='utf-8')) for p in pathlib.Path('.github/workflows').glob('*.yml')]; print('PASS: parsed workflow YAML files')"` | 0 | Parsed workflow YAML |
| `git diff --check` | 0 | Clean |

Fresh controller browser API E2E also passed on isolated local `127.0.0.1:18903` with temporary SQLite/report roots. The test covered admin/teacher access, Chinese search, autosave persistence, stale edit conflict, four report links/files, soft trash/restore, admin/audit surfaces, empty console warn/error output, clean server stderr, and released port.

Boundary: this local/browser proof used temporary SQLite and local report storage. It is not PostgreSQL or NAS hardware evidence.