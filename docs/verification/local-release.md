# Local Release Candidate Verification

**Verification date:** 2026-08-26 12:00:16 +08:00
**Worktree:** `F:\Git\科创诊断报告生成器优化\.worktrees\nas-centralized-app`
**Released candidate commit:** `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`
**Release tag:** `v0.1.0`
**Verdict:** Task 6 local release-candidate gates are complete for local/CI/browser/published-image evidence, but this is **not** NAS hardware proof and **not** real PostgreSQL/NAS runtime proof.

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
| Secret scan | CI-equivalent `git grep -n -I -E '(AKIA[0-9A-Z]{16}|-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----|ghp_[A-Za-z0-9_]{36,}|sk-[A-Za-z0-9]{20,})' -- . ':!server/uv.lock' ':!vendor/*'` | 0 | No committed secret material matched |
| Workflow YAML parse | `python -c "import yaml, pathlib; [yaml.safe_load(p.read_text(encoding='utf-8')) for p in pathlib.Path('.github/workflows').glob('*.yml')]; print('PASS: parsed workflow YAML files')"` | 0 | Parsed successfully |
| Git whitespace check | `git diff --check` | 0 | No whitespace errors |

The Python skip count is expected locally on Windows: the PostgreSQL grant integration remains skipped without a live PostgreSQL URL, and the POSIX mode-bit CLI test is skipped on Windows. CI on Linux reported 84 passed, 1 skipped.

## Final CI and Release Evidence

Final head CI was verified with `gh run view 32925836784 --repo liwlin/innovation-diagnostic-report-generator`:

- Run URL: <https://github.com/liwlin/innovation-diagnostic-report-generator/actions/runs/32925836784>
- Head SHA: `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`
- Status/conclusion: `completed` / `success`
- Jobs green: Static site, Compose, and script verifiers; Workflow policy; Secret scan; Node tests; Python tests, Ruff, and mypy; Docker build without push.

Release was verified with `gh run view 32925993328 --repo liwlin/innovation-diagnostic-report-generator`:

- Run URL: <https://github.com/liwlin/innovation-diagnostic-report-generator/actions/runs/32925993328>
- Head SHA: `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`
- Status/conclusion: `completed` / `success`
- Jobs green: Re-verify release commit; Publish allowlisted Pages artifact; Publish GHCR image, SBOM, provenance, and vulnerability gate.
- Release checks include Python/Ruff/mypy, Node, static/policy verifiers, Pages allowlist/deploy, GHCR push, CycloneDX SBOM, HIGH/CRITICAL fixed-vulnerability scan, provenance attestation, and manifest upload.

`git ls-remote --tags origin "refs/tags/v0.1.0^{}"` returned `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`, so tag `v0.1.0` resolves exactly to the released candidate commit.

## Pages and Browser Evidence

Published Pages URL: <https://liwlin.github.io/innovation-diagnostic-report-generator/>

`runtime-config.js` was fetched and matched the release boundary:

```js
window.__MKSEED_RUNTIME__=Object.freeze({"commitSha":"ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0","storageMode":"local","appVersion":"v0.1.0","apiBaseUrl":""});
```

Controller browser evidence against Pages:

- In-app Browser title: `科创体验报告 · 生成器`.
- Final editor URL and visible DOM were meaningful.
- AI settings opened then closed.
- Desktop `1366x768` and mobile `390x844` controls remained accessible.
- Browser console warn/error output was empty.
- No NAS API address was present in runtime config.
- IAB screenshot method failed with `Unable to capture screenshot`; screenshot capture is unavailable, not passed.

Fresh browser API E2E was completed by the controller on isolated local `127.0.0.1:18903` using a temporary SQLite database/report root, then the port was released:

- Admin login showed all records; teacher login showed all 6 shared records and no admin navigation.
- Chinese search `张子涵` narrowed to 1 record.
- Editor autosave changed an observation, showed `已保存`, and persisted after reload.
- Independent teacher-B HTTP session updated version `3->4`; stale browser edit showed `记录已被其他老师修改，请重新加载`.
- Generation completed with four links: without/with PDF/PNG.
- Report files used exact legacy names; sizes were 73,197 / 224,736 / 81,127 / 288,101 bytes; partial count 0.
- Soft trash via isolated API was visible in Browser recycle with restore/report/permanent-delete controls; Browser restore removed it from recycle.
- Admin accounts and audit were visible; audit included generation/update/trash/restore.
- Browser console warn/error output was empty; server stderr was clean.

This browser E2E proves local app behavior with temporary SQLite/report storage only. It is not PostgreSQL or NAS hardware evidence.

## Published Image Evidence

Registry tag `0.1.0` was verified by HTTP HEAD against GHCR manifest endpoint with a bearer pull token:

- HTTP status: 200
- `Docker-Content-Digest`: `sha256:996d991c215fc30f62ea782315b76d093cda0d8da98fd058fea2a60e6c4ca718`

The local GitHub package REST query returned 403 because the local `gh` token lacks `read:packages`; that REST limitation does not block the registry digest proof above.

Published image evidence:

- GHCR index digest: `sha256:996d991c215fc30f62ea782315b76d093cda0d8da98fd058fea2a60e6c4ca718`
- Linux/amd64 manifest digest: `sha256:256eea792348d1a576b628b2e48e9fbfcd844ea2745df91003becec420948cc3`
- Config digest: `sha256:2cef241b6cc638cb7dd1703a2444904c8690c7e8c931a0a9dd4dcb4bb3c45dba`
- Layer count: 14
- User: `10001:10001`
- CMD: Uvicorn running `makerseed_app.main:app`, one worker, no access log.
- Env/labels bind version `v0.1.0` and commit `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`.

Release evidence artifacts:

- `release-manifest.json` SHA-256: `b6fa5342a6d78f2eae0d8cf7fff03dea86c0a89a9a82495a886352ad8207fa3`
- `sbom.cdx.json` SHA-256: `fc020f7306905e28363418ffd68b9318bfd41aed9611e16c4adedbba1caae1d6`
- SBOM format: CycloneDX 1.6
- SBOM components: 153
- SBOM subject: exact image digest `sha256:996d991c215fc30f62ea782315b76d093cda0d8da98fd058fea2a60e6c4ca718`

`gh attestation verify oci://ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:996d991c215fc30f62ea782315b76d093cda0d8da98fd058fea2a60e6c4ca718 --repo liwlin/innovation-diagnostic-report-generator --signer-workflow liwlin/innovation-diagnostic-report-generator/.github/workflows/release.yml --source-digest ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0 --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners --format json` returned exit 0. The SLSA provenance v1 subject is the exact index digest, and the source ref/digest match `refs/tags/v0.1.0` and `ddc9164bfd8320d9a56bfa4f2124c5253a64d6c0`.

OCI layer inspection was performed in ignored scratch and did not commit layer contents:

- Downloaded all 14 layers, about 92 MiB.
- Every layer SHA matched.
- Inspected 10,420 paths.
- Path traversal findings: 0.
- Expected `index.html`, logos, shared runtime, vendor React, and Alembic files present.
- Secret pattern matches: 0.
- Project tests, docs, deploy files, `.git`, `.env`, and secrets absent.
- Only third-party `greenlet` package tests were present under `.venv`; this is a minor image-slimming observation, not project test leakage and not a secret finding.

## Remaining NAS Gates

Task 7 still requires DS220+ proof before any NAS claim:

- Run PostgreSQL grant tests against the real `db` target.
- Run deployment preflight and prove write isolation on the NAS.
- Start and inspect the two actual NAS containers.
- Verify DSM HTTPS reverse proxy, File Station ACLs, Cloud Sync isolation, backup/restore, restart recovery, rollback, resource use, and company-data non-impact.

## Boundary Statement

Task 6 is complete for local release-candidate verification, published image evidence, Pages/browser evidence, and release provenance. This evidence still does not prove NAS deployment, NAS security posture, DSM HTTPS behavior, File Station ACLs, Cloud Sync isolation, real PostgreSQL grants, backup restore on DS220+, rollback on DS220+, or hardware runtime behavior.