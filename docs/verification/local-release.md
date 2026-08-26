# Local Release Candidate Verification

**Verification date:** 2026-08-26 11:03:11 +08:00
**Worktree:** `F:\Git\科创诊断报告生成器优化\.worktrees\nas-centralized-app`
**Commit:** `3a7da7354e4d87090f26c0c179c4cb73c354991b`
**Branch:** `feature/nas-centralized-app`
**Verdict:** local and CI checks are green for the surfaces they executed, but this is **not** a NAS proof and is **not** a published-image release proof.

## Local Verifier Results

| Check | Command | Exit | Result |
| --- | --- | ---: | --- |
| Python tests | `uv run --project server pytest` | 0 | 85 collected; 83 passed, 2 skipped; 24.15s |
| Ruff | `uv run --project server ruff check` | 0 | All checks passed |
| mypy | `uv run --project server mypy server/src/makerseed_app` | 0 | Success; 45 source files checked |
| Node tests | `node --test tests/js/*.test.js` | 0 | 28 passed, 0 failed, 0 skipped |
| Static Pages | `pwsh -NoProfile -File tests/verify-static-site.ps1` | 0 | Required static runtime files available |
| Compose hardening | `pwsh -NoProfile -File tests/verify-compose-security.ps1` | 0 | Two hardened digest-pinned services verified |
| Compose config | `docker compose -f deploy/compose.yaml config --quiet` with dummy non-secret release environment | 0 | Parsed successfully |
| Deploy-script safety | `pwsh -NoProfile -File tests/verify-deploy-scripts.ps1` | 0 | Guarded scripts and backup/restore contracts verified |
| Workflow policy | `pwsh -NoProfile -File tests/verify-workflows.ps1` | 0 | Pinned, least-privilege, test-gated, release-scoped |
| Secret scan | CI-equivalent `git grep` pattern excluding `server/uv.lock` and `vendor/*` | 0 | No committed secret material matched |
| Workflow YAML parse | Python `yaml.safe_load` over `.github/workflows/*.yml` | 0 | Parsed successfully |
| Git whitespace check | `git diff --check` | 0 | No whitespace errors |

The Python skip count is expected locally on Windows: the PostgreSQL grant integration remains skipped without a live PostgreSQL URL, and the POSIX mode-bit CLI test is skipped on Windows. CI on Linux reported a different split: 84 passed, 1 skipped.

## Browser Evidence

Fresh runnable browser E2E was not completed in this verification pass. The repository has `tests/browser/dual-mode.spec.js`, but it is a stable flow contract for the Codex in-app Browser workflow rather than an executable Playwright suite, and no local Playwright runtime was available without adding a dependency.

Prior browser evidence exists in `docs/verification/dual-mode-frontend.md` for local SQLite/browser flows, but it was not refreshed here. This keeps Task 6 Step 1 incomplete.

## CI Evidence

`gh run view 32924316381 --repo liwlin/innovation-diagnostic-report-generator` verified:

- Run URL: <https://github.com/liwlin/innovation-diagnostic-report-generator/actions/runs/32924316381>
- Head SHA: `3a7da7354e4d87090f26c0c179c4cb73c354991b`
- Status/conclusion: `completed` / `success`
- Event: `push`
- Jobs green: Workflow policy; Python tests, Ruff, and mypy; Node tests; Secret scan; Static site, Compose, and script verifiers; Docker build without push.

This CI run proves only those executed checks. The Docker job built locally with `push: false`; it did not create a GHCR digest.

## Static Image and Release Intent Inspection

`deploy/Dockerfile` statically declares:

- Digest-pinned Python 3.12 slim Bookworm base image.
- Runtime OCI labels for title, source, version, and revision.
- Runtime user `10001:10001`.
- Uvicorn command with one worker and no access log.
- Static assets copied from `index.html`, the source editor HTML, `support.js`, `doc-page.js`, `assets`, `shared`, `vendor`, and `nas-web`.
- Package-manager cache cleanup after installing CJK fonts and certificates.

`deploy/compose.yaml` statically declares:

- Exactly two services: `app` and `db`.
- App loopback binding only: `127.0.0.1:18081`.
- No PostgreSQL host port.
- Non-root users, read-only root filesystems, dropped capabilities, `no-new-privileges`, PID/memory/CPU bounds, tmpfs, JSON log rotation, and internal network.
- Secret files under `${SECRETS_ROOT}` and project/report bind mounts under explicit environment variables.

`.github/workflows/release.yml` statically declares:

- Release only on `v*` tag push or explicit dispatch against an immutable SemVer tag.
- Re-verification before Pages publish and image publish.
- GHCR tags for SemVer and commit SHA, not `latest`.
- SBOM generation, Trivy HIGH/CRITICAL gate, provenance attestation, and release manifest.

These are static intent checks only. They are not a substitute for inspecting a published image digest.

## Incomplete Release Gates

Task 7 must remain blocked until all of the following are completed:

- Create a release tag from the verified commit or another reviewed commit.
- Run the release workflow and capture the published GHCR digest.
- Inspect the published image user, entrypoint/CMD, OCI labels, embedded version/revision, layers for secret filenames/content, expected static assets, SBOM, vulnerability verdict, and provenance.
- Run a fresh real-browser E2E pass against a temporary database/report root, or add and run an executable browser harness without broadening release risk.
- Run PostgreSQL grant tests against a real PostgreSQL container or the NAS database target.
- Perform Task 7 DS220+ proof before claiming NAS runtime behavior, File Station visibility, DSM reverse proxy, Cloud Sync, backup restore, restart recovery, rollback, resource use, or company-data non-impact.

## Boundary Statement

This evidence does not prove NAS deployment, NAS security posture, DSM HTTPS behavior, File Station ACLs, Cloud Sync isolation, real PostgreSQL grants, published image contents, SBOM/vulnerability output, or hardware runtime. It is a local/CI release-candidate readiness record with explicit gates before any NAS write.
