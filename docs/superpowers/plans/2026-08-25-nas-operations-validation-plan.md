# NAS Operations, Security, Release, and Hardware Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the completed app as a hardened two-container Synology deployment, automate safe backup/update/rollback, publish versioned GitHub artifacts, and prove the full system on the DS220+ without touching company data or existing services.

**Architecture:** The long-running project contains only `app` and `db`; one-shot maintenance commands reuse the app image without adding a resident service. Compose binds the app to host loopback, leaves PostgreSQL unexposed, mounts only new project-owned paths, and applies non-root/read-only/capability/resource controls. CI produces immutable GHCR images from the same commit as Pages, while NAS scripts enforce exact-root guards, pre-update backup, health verification, and rollback.

**Tech Stack:** Docker/OCI, standalone Synology `docker-compose` v2.20.x, PostgreSQL official image, Debian-based Python image, GitHub Actions, GHCR, Trivy or equivalent pinned vulnerability scanner, POSIX shell on DSM, PowerShell static verifiers, Cloud Sync to Baidu Cloud, SSH with a temporary source-restricted key.

**Spec:** `docs/superpowers/specs/2026-08-25-nas-centralized-app-design.md`

## Global Constraints

- Exactly two long-running containers: `app` and `db`.
- App host port binds only `127.0.0.1`; PostgreSQL publishes no host port.
- App runs non-root, read-only root filesystem, `cap_drop: ALL`, `no-new-privileges`, bounded PIDs/CPU/memory, and bounded tmpfs.
- No service may mount Docker Socket, devices, host network, company shares, NAS root, `/volume1`, or any path outside the exact project/report/backup roots.
- Production images use explicit version plus digest; `latest`, Watchtower, and automatic database major upgrades are forbidden.
- Existing Container Manager projects, containers, networks, volumes, shared folders, Cloud Sync tasks, QuickConnect, DDNS, router, DNS, and company data remain unchanged.
- Automated NAS writes begin only after exact target-path and name-collision checks pass.
- Initial hardware verification uses loopback port `18081` through a permit-open SSH tunnel; no LAN/external route is created before application and security tests pass.
- Cloud Sync is configured as a new project-specific task; no existing task is edited.
- PostgreSQL cloud backup cadence is monthly plus before every app/schema upgrade; reports sync independently.
- Completion requires a real backup restore into a disposable validation database, not only `pg_restore --list`.

---

## Locked File Structure

```text
.dockerignore
deploy/
  Dockerfile
  compose.yaml
  compose.override.test.yaml
  env.example
  postgres-init/10-create-runtime-role.sh
  scripts/common.sh
  scripts/preflight.sh
  scripts/install-layout.sh
  scripts/migrate.sh
  scripts/backup.sh
  scripts/restore-verify.sh
  scripts/deploy.sh
  scripts/rollback.sh
  scripts/smoke.sh
  synology/cloud-sync-baidu.md
  synology/dsm-reverse-proxy.md
  synology/file-station-acl.md
  synology/monthly-task.md
tests/
  verify-compose-security.ps1
  verify-deploy-scripts.ps1
.github/workflows/
  ci.yml
  release.yml
docs/verification/
  local-release.md
  nas-hardware.md
  nas-impact-audit.md
  artifacts/nas/
```

## Fixed NAS Isolation Names

```text
Compose project: makerseed-diagnostic
Staging loopback port: 18081
Project root: /volume1/docker/makerseed-diagnostic
Database root: /volume1/docker/makerseed-diagnostic/data/postgres
Backup staging: /volume1/docker/makerseed-diagnostic/backups
Temporary report root: /volume1/docker/makerseed-diagnostic/reports-staging
Final dedicated share: 科创诊断报告
```

If `/volume1/docker` is not the verified Docker parent on the device, stop before writing and update this plan/spec through an explicit reviewed change. Never probe alternative company share contents to guess a location.

## Task 1: Hardened Image and Two-Container Compose

**Files:**
- Create: `.dockerignore`
- Create: `deploy/Dockerfile`
- Create: `deploy/compose.yaml`
- Create: `deploy/compose.override.test.yaml`
- Create: `deploy/env.example`
- Create: `deploy/postgres-init/10-create-runtime-role.sh`
- Create: `tests/verify-compose-security.ps1`

**Interfaces:**
- Consumes: locked Python app, static assets, secret files, dedicated host directories, and pinned image digests.
- Produces: one non-root app image and two long-running Compose services named `app` and `db` inside project `makerseed-diagnostic`.

- [x] **Step 1: Write a failing Compose security verifier**

The PowerShell verifier runs `docker compose -f deploy/compose.yaml config --format json` without requiring a daemon and asserts:

```powershell
$services.PSObject.Properties.Name | Sort-Object | Should-Be @('app','db')
$services.app.ports[0].host_ip | Should-Be '127.0.0.1'
$services.db.ports.Count | Should-Be 0
$services.app.read_only | Should-Be $true
$services.app.cap_drop | Should-Contain 'ALL'
$services.app.security_opt | Should-Contain 'no-new-privileges:true'
```

It must fail if any service uses `privileged`, `network_mode: host`, Docker Socket, device mounts, `latest`, unbounded writable root, `/volume1` broad mount, or an unapproved host path.

- [x] **Step 2: Run the verifier and confirm missing Compose**

Run: `pwsh -NoProfile -File tests/verify-compose-security.ps1`

Expected: fail because `deploy/compose.yaml` is absent.

- [x] **Step 3: Create a digest-pinned multi-stage app image**

Use a digest-pinned Python 3.12 slim Debian base. The build stage installs the locked wheel set; the runtime stage installs only Noto CJK font and required shared libraries, copies the virtual environment and static assets, creates UID/GID `10001`, and sets `USER 10001:10001`. Entrypoint runs Uvicorn with one worker and no reload. Do not place a shell package manager cache, Git metadata, tests, secrets, uploads, `.omx`, or local preview files in the runtime image.

- [x] **Step 4: Create the two-service Compose file**

`app` uses `user: "10001:10001"`, `read_only: true`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `pids_limit: 128`, `mem_limit: 1536m`, `cpus: 1.5`, bounded `/tmp` tmpfs, loopback port `18081`, project-only report mount, explicit secrets, JSON log rotation, and healthcheck.

`db` uses a digest-pinned supported PostgreSQL major, `user: "999:999"` after pre-created directory ownership, `read_only: true`, `cap_drop: [ALL]`, `security_opt`, `pids_limit`, `mem_limit: 2048m`, `cpus: 1.0`, `/tmp` and `/var/run/postgresql` tmpfs, project-only data/backup mounts, file-based password, log rotation, and `pg_isready` healthcheck. It uses no host port.

The shared Docker network is `internal: true`. The app depends on `db` with `condition: service_healthy` supported by the verified Synology Compose version.

- [x] **Step 5: Create a safe PostgreSQL role initializer**

The initializer reads owner/runtime passwords from `/run/secrets`, passes values to `psql` variables rather than interpolating SQL text, creates the runtime role without CREATEDB/CREATEROLE/SUPERUSER/BYPASSRLS, and grants only required table/sequence privileges. A later migration grant explicitly omits UPDATE/DELETE on `audit_events`.

- [x] **Step 6: Run config and security checks**

Run:

```powershell
docker compose -f deploy/compose.yaml config --quiet
pwsh -NoProfile -File tests/verify-compose-security.ps1
git check-ignore .env secrets/session_secret secrets/postgres_owner_password
```

Expected: all pass and every secret path is ignored.

- [x] **Step 7: Commit container boundaries**

Record two-container count, loopback/no-DB-port, mounts, non-root/read-only/capability/resource controls, digest policy, and config verification.

## Task 2: Database Ownership, Migrations, Bootstrap, and PostgreSQL Integration

**Files:**
- Create: `deploy/scripts/common.sh`
- Create: `deploy/scripts/migrate.sh`
- Modify: `server/alembic/versions/0001_initial_schema.py`
- Create: `server/src/makerseed_app/cli.py`
- Create: `server/tests/postgres/test_postgres_security.py`
- Create: `server/tests/test_cli.py`

**Interfaces:**
- Consumes: owner secret only in maintenance command, runtime role secret in app, Alembic migrations, and bootstrap secret.
- Produces: migrated schema, append-only audit grants, and one-time admin creation.

- [x] **Step 1: Write failing CLI and PostgreSQL grant tests**

Test that `bootstrap-admin` refuses a non-TTY password argument, accepts password from an exact secret file, creates one admin, refuses rerun without a rotate flag, and logs no password. PostgreSQL integration uses the runtime role to prove INSERT/SELECT on `audit_events` succeeds while UPDATE/DELETE raises insufficient privilege.

- [x] **Step 2: Run local CLI tests and verify missing command**

Run: `uv run --project server pytest server/tests/test_cli.py -q`

Expected: import/command failure.

- [x] **Step 3: Implement a one-shot maintenance path**

`migrate.sh` validates exact project root, runs the app image with owner secret and internal network, applies Alembic, applies runtime grants, and exits. No owner password is granted to the long-running app. `bootstrap-admin` reads username/display name from bounded environment variables and password from a mode-0600 secret file, then deletes or archives the bootstrap secret through an explicit admin step after success.

- [x] **Step 4: Run CLI tests and defer only real PostgreSQL evidence**

Run:

```powershell
uv run --project server pytest server/tests/test_cli.py -q
uv run --project server ruff check server/src/makerseed_app/cli.py
```

Expected: pass. Mark PostgreSQL grant tests pending until the isolated container is available; do not substitute SQLite success.

- [x] **Step 5: Commit maintenance-role separation**

Record owner/runtime separation, append-only audit intent, CLI secret handling, and the explicit remaining PostgreSQL verification.

## Task 3: Safe Backup, Real Restore Verification, and Cloud Sync Runbooks

**Files:**
- Create: `deploy/scripts/backup.sh`
- Create: `deploy/scripts/restore-verify.sh`
- Create: `deploy/synology/cloud-sync-baidu.md`
- Create: `deploy/synology/monthly-task.md`
- Create: `tests/verify-deploy-scripts.ps1`

**Interfaces:**
- Consumes: exact project root, running `db`, backup mount, app/schema versions, and Cloud Sync UI.
- Produces: timestamped custom-format dump, SHA-256 manifest, disposable restore verdict, and isolated monthly/upload-only encrypted task instructions.

- [ ] **Step 1: Write failing static script-safety tests**

The verifier asserts every mutating script calls `require_exact_project_root`, contains no `rm -rf`, no broad `/volume1` target, no unquoted destructive glob, no company share path, and no secret echo. It checks backup names match `makerseed_<UTC>_<app-version>.dump` and manifests include schema/app/hash fields.

- [ ] **Step 2: Run verifier and confirm scripts are absent**

Run: `pwsh -NoProfile -File tests/verify-deploy-scripts.ps1`

Expected: fail on missing scripts.

- [ ] **Step 3: Implement consistent backup with fail-closed staging**

`backup.sh` verifies exact resolved root, free space, healthy database, and writable dedicated backup directory. It runs one non-parallel `pg_dump --format=custom --no-owner --no-acl`, writes `.partial`, runs `pg_restore --list`, computes SHA-256, writes a JSON manifest without secrets, fsyncs, renames atomically, and leaves previous successful dumps untouched on failure.

- [ ] **Step 4: Implement a real disposable restore test**

`restore-verify.sh` validates the manifest/hash, creates a randomly named validation database inside the same isolated PostgreSQL container, restores the dump, runs schema/table/row-count/invariant checks, records the verdict, and drops only that exact validation database after checking its generated prefix. It must never restore over the live database.

- [ ] **Step 5: Document project-specific Cloud Sync settings**

The Baidu task runbook requires a new task owned by a dedicated non-personal DSM account, local project reports/backup paths only, `Upload local changes only`, `Do not remove destination data when source is removed`, client-side encryption, key export, two offline key copies, no editing of `@SynologyCloudSync`, and no changes to existing tasks. The monthly DSM task runs backup plus restore verification; pre-upgrade backup is called by deployment regardless of schedule.

- [ ] **Step 6: Run safety checks**

Run: `pwsh -NoProfile -File tests/verify-deploy-scripts.ps1`

Expected: pass. Actual dump/restore remains unproven until PostgreSQL/NAS execution.

- [ ] **Step 7: Commit backup and recovery controls**

Record custom-format dump, atomic manifest, real disposable restore design, monthly/pre-upgrade cadence, and Cloud Sync non-interference.

## Task 4: Versioned Deploy, Health Gate, Smoke Test, and Rollback

**Files:**
- Create: `deploy/scripts/preflight.sh`
- Create: `deploy/scripts/install-layout.sh`
- Create: `deploy/scripts/smoke.sh`
- Create: `deploy/scripts/deploy.sh`
- Create: `deploy/scripts/rollback.sh`
- Create: `deploy/synology/dsm-reverse-proxy.md`
- Create: `deploy/synology/file-station-acl.md`
- Modify: `tests/verify-deploy-scripts.ps1`

**Interfaces:**
- Consumes: exact version/digest, project root, secrets, prior deployment state, and app health/API.
- Produces: guarded installation, pre-update backup, migration, deployment state, automatic rollback, DSM proxy/ACL runbooks.

- [ ] **Step 1: Extend failing script tests**

Require preflight collision checks, exact target check before directory creation, no broad recursive delete, previous version/digest persistence, pre-upgrade backup before migration, health timeout, authenticated smoke hook, rollback on failure, and removal of temporary bootstrap material.

- [ ] **Step 2: Implement read-only preflight**

`preflight.sh` verifies architecture `x86_64`, required Docker/Compose versions, exact parent path, sufficient disk/memory, target path state, unique Compose project/container/port, required images or import bundles, secret modes, and that all declared mounts resolve under approved roots. It outputs a machine-readable verdict and performs no writes.

- [ ] **Step 3: Implement one-time isolated layout creation**

`install-layout.sh` runs only after a successful preflight nonce, creates exact project subdirectories without following symlinks, applies UID/GID/modes, creates no shared folder or DSM account, and refuses any pre-existing unexpected file.

- [ ] **Step 4: Implement versioned deployment and smoke**

`deploy.sh` verifies image digest, saves current state, runs backup and disposable restore verification, migrates, recreates only `app`, waits for health, and calls `smoke.sh`. Smoke verifies health, unauthenticated 401, login with a temporary test account, CSRF rejection, authenticated session, create/search/update/trash/restore, and then removes test data through the application. Any failure invokes rollback.

- [ ] **Step 5: Implement rollback**

Rollback restores the previous app image/digest and Compose release. If the deployment changed schema incompatibly, it stops app, restores the exact pre-upgrade dump into the project database through a separately confirmed path, then starts the prior app. The script refuses to act without a valid prior-state file and verified backup hash.

- [ ] **Step 6: Document final DSM boundaries**

Reverse proxy runbook creates a new LAN-only HTTPS entry targeting `127.0.0.1:18081`; it does not modify QuickConnect. File Station runbook creates only the exact encrypted share `科创诊断报告`, grants the app service identity write, a dedicated teacher DSM group read-only, admin manage, and all others none. It explicitly requires the user's teacher DSM account list before adding members.

- [ ] **Step 7: Run static script and Compose checks**

Run:

```powershell
pwsh -NoProfile -File tests/verify-deploy-scripts.ps1
pwsh -NoProfile -File tests/verify-compose-security.ps1
docker compose -f deploy/compose.yaml config --quiet
```

Expected: all pass.

- [ ] **Step 8: Commit deploy/rollback automation**

Record exact-root guards, preflight non-mutation, backup-before-migration, health/smoke gate, and rollback constraints.

## Task 5: GitHub CI, Pages, GHCR, SBOM, and Vulnerability Gate

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Create: `tests/verify-workflows.ps1`
- Modify: `index.html`
- Modify: `server/src/makerseed_app/config.py`

**Interfaces:**
- Consumes: Git commit/tag, locked dependencies, Dockerfile, all local tests, and GitHub OIDC/package permissions.
- Produces: Pages artifact, immutable GHCR image/digest, SBOM, signed provenance where available, and release evidence.

- [ ] **Step 1: Write failing workflow-policy tests**

Assert actions are pinned to full commit SHAs, permissions are least-privilege, PR CI has no package write, release only runs on `v*` tags or explicit dispatch, tests precede build/publish, image tags include semver and commit SHA, vulnerability scan blocks HIGH/CRITICAL unfixed findings, Pages artifact contains no server/secrets/deploy runtime data, and no workflow uses floating action tags.

- [ ] **Step 2: Run policy tests and verify workflows are absent**

Run: `pwsh -NoProfile -File tests/verify-workflows.ps1`

Expected: fail on missing workflows.

- [ ] **Step 3: Implement CI**

CI runs Python tests/Ruff/mypy, Node tests, static Pages verifier, Compose/script/workflow verifiers, secret scan, and Docker build without push. Cache keys derive from `server/uv.lock`. No test uses production secrets.

- [ ] **Step 4: Implement release**

Release rebuilds from the tagged commit, verifies all tests, publishes Pages local mode, pushes `ghcr.io/liwlin/innovation-diagnostic-report-generator:<semver>` and `:<commit-sha>`, records digest, emits SBOM/provenance, scans the final digest, and creates a release manifest with Pages commit and NAS image digest. Do not emit `latest`.

- [ ] **Step 5: Run workflow and full local static checks**

Run:

```powershell
pwsh -NoProfile -File tests/verify-workflows.ps1
pwsh -NoProfile -File tests/verify-static-site.ps1
pwsh -NoProfile -File tests/verify-compose-security.ps1
pwsh -NoProfile -File tests/verify-deploy-scripts.ps1
```

Expected: all pass.

- [ ] **Step 6: Commit and push for CI evidence**

Commit workflows and version wiring with Lore trailers, push the reviewed branch, wait for CI, and record exact run URLs and conclusions. A green workflow counts only for the checks it actually executed.

## Task 6: Complete Local Release Candidate Verification

**Files:**
- Create: `docs/verification/local-release.md`
- Create: `docs/verification/artifacts/local/`

**Interfaces:**
- Consumes: full repository, CI artifact/image digest, Browser verification, and all plan tests.
- Produces: release-candidate verdict before any NAS write.

- [ ] **Step 1: Run every local verifier from a clean checkout state**

Run Python tests, Ruff, mypy, all Node tests, static Pages test, Compose security, deploy-script safety, workflow policy, and browser E2E against a temporary database/report root. Record exact counts and exit codes.

- [ ] **Step 2: Inspect the built image artifact**

Use the CI-published digest. Inspect user, entrypoint, labels, SBOM, vulnerability verdict, layers for secret filenames/content, and expected static assets. Confirm the tag and embedded version map to the same commit.

- [ ] **Step 3: Record release-candidate evidence**

State explicitly that local/CI evidence is not NAS proof. Block Task 7 unless every prerequisite passes and the only remaining writes are the exact isolated NAS targets.

- [ ] **Step 4: Commit local evidence**

Commit non-sensitive evidence and artifact summaries; do not commit downloaded image tarballs, secrets, cookies, or screenshots containing real student/company data.

## Task 7: DS220+ Isolated Hardware Deployment and Full-Flow Proof

**Files:**
- Create: `docs/verification/nas-hardware.md`
- Create: `docs/verification/nas-impact-audit.md`
- Create: `docs/verification/artifacts/nas/`
- Modify: `docs/superpowers/plans/2026-08-25-nas-operations-validation-plan.md`

**Interfaces:**
- Consumes: approved release digest, safe scripts, temporary source-restricted SSH authorization, DS220+ Docker/Compose, and exact isolated paths.
- Produces: real container, database, report, backup/restore, restart, rollback, resource, port, mount, and non-impact evidence.

- [ ] **Step 1: Establish temporary least-privilege automation access**

Generate a new ephemeral Ed25519 key locally. The user adds it to root `authorized_keys` with `from=<current workstation IP>`, `no-agent-forwarding`, `no-X11-forwarding`, `no-pty`, and `permitopen="127.0.0.1:18081"`. Never request or capture the NAS password. Record the public-key fingerprint, not the private key.

- [ ] **Step 2: Capture a read-only before-state without reading company data**

Record NAS kernel/architecture, free memory, target volume free space, Docker/Compose versions, exact target path existence, app port availability, and existing container names/status only. Do not enumerate shared-folder contents, volume contents, databases, container mounts, environment variables, or Cloud Sync task details.

- [ ] **Step 3: Run preflight and verify zero writes on failure**

Transfer signed/checksummed release scripts into a temporary project-named staging path, run `preflight.sh`, and compare target path/container state before/after. Any collision, symlink, port use, unverified digest, or secret-mode failure stops the deployment.

- [ ] **Step 4: Install exact isolated layout and secrets**

Create only `/volume1/docker/makerseed-diagnostic` children. Generate database/session/bootstrap secrets on NAS with mode `0600`; do not print or transfer them back. Load/pull only the verified image digests. Run migrations and one-time admin bootstrap, then invalidate/remove bootstrap material.

- [ ] **Step 5: Start two containers and inspect hardening**

Run `docker-compose -p makerseed-diagnostic up -d app db`. Prove exactly two project containers, healthy state, app host binding `127.0.0.1:18081`, no PostgreSQL host port, expected read-only rootfs, user IDs, dropped capabilities, no-new-privileges, PIDs/memory/CPU limits, internal network, and only approved mounts.

- [ ] **Step 6: Execute real PostgreSQL and browser workflows through the tunnel**

Run PostgreSQL grant tests against the real `db`. Open an SSH tunnel limited to `127.0.0.1:18081`, then run browser flows for admin/two teachers, cross-teacher search/edit, 409 conflict, recycle/restore, admin permanent delete, audit, AI metadata without key, emergency import, and version display.

- [ ] **Step 7: Generate and inspect real NAS artifacts**

Generate four reports from non-sensitive fixture data. Verify exact names, readable Chinese, internal watermark, parent-data separation, hashes, MIME, immutable history, safe human-readable directory, app download, and visibility in the project report path. Confirm no container can resolve a path outside approved roots.

- [ ] **Step 8: Prove restart recovery, monthly backup, and real restore**

Queue a generation, restart only the app, and prove recovery. Run `backup.sh`, verify manifest/hash, run `restore-verify.sh` into a disposable database, and compare invariant counts. Keep the successful encrypted-ready backup in project staging; do not edit any existing Cloud Sync task.

- [ ] **Step 9: Prove update and rollback**

Deploy a distinct signed test build or previous verified version, observe pre-update backup, health/smoke gate, and version change, then run rollback and verify prior version/data. PostgreSQL remains running through ordinary app rollback.

- [ ] **Step 10: Configure final DSM surfaces only after isolation passes**

Create the exact dedicated encrypted report share and read-only teacher group after obtaining the teacher DSM usernames; create a new LAN-only DSM HTTPS reverse proxy to loopback. Create a new project-only Cloud Sync task and upload a non-sensitive encrypted fixture, then verify decryptability using the exported key copy. Existing tasks are read-only comparison targets and are not edited.

- [ ] **Step 11: Capture after-state and prove company-data non-impact**

Compare existing container names/status, DSM network/QuickConnect state, and target volume free space to the before-state. Inspect only this project's mounts and paths. State whether any unrelated container restarted or changed; expected result is none. Do not hash or inspect company files as a means of proof.

- [ ] **Step 12: Remove temporary access and sensitive test material**

Remove the exact ephemeral authorized-key line, delete the local private/public key files, verify key login is rejected, remove non-sensitive test accounts/records through the app, close the SSH tunnel, and preserve only the approved production service, reports, encrypted backup, and non-secret evidence.

- [ ] **Step 13: Record hardware verdict and commit evidence**

`nas-hardware.md` separates verified facts from limitations and includes commands/output summaries, container IDs/digests, version, timestamps, test results, artifact hashes, backup/restore ID, restart/rollback results, resource peaks, and access-removal proof. `nas-impact-audit.md` lists exact touched paths/resources and confirms unrelated state. Commit only sanitized evidence.

## Task 8: Requirement-by-Requirement Completion Audit

**Files:**
- Create: `docs/verification/final-completion-audit.md`
- Modify: all four implementation plan checkbox states based on evidence.

**Interfaces:**
- Consumes: design sections, four plans, current repository, CI, browser, and NAS evidence.
- Produces: a complete evidence matrix and final goal verdict.

- [ ] **Step 1: Build the evidence matrix**

For every requirement in design sections 2-17, name the exact code file, automated test, runtime/browser proof, NAS proof where applicable, and result. Mark missing or indirect evidence as incomplete.

- [ ] **Step 2: Re-run final critical checks**

Re-run full Python/Node/static/security tests, query current Git/CI state, check NAS container health and app version, verify latest backup/restore result, and confirm temporary key rejection.

- [ ] **Step 3: Resolve every incomplete item**

Do not reduce scope or convert an unverified item into a documentation-only claim. Fix and repeat the relevant verification until the matrix contains no required incomplete item.

- [ ] **Step 4: Commit the final audit and close the goal only with complete proof**

Commit the sanitized audit, ensure the worktree is clean and pushed as intended, then call goal completion only if every explicit objective is proven.

