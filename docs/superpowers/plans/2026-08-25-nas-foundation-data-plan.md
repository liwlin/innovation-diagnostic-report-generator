# NAS Foundation and Central Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tested FastAPI application with centralized PostgreSQL-compatible data, independent teacher login, shared record access, optimistic concurrency, audit history, recycle-bin recovery, and admin-only permanent deletion.

**Architecture:** A Python 3.12 package exposes same-origin JSON APIs and later serves the static frontend. SQLAlchemy models use portable JSON in SQLite unit tests and PostgreSQL JSONB in production. Opaque server-side sessions, CSRF double-submit tokens, explicit role checks, version-qualified updates, and same-transaction audit inserts enforce the approved security boundary.

**Tech Stack:** Python 3.12, FastAPI, Pydantic Settings, SQLAlchemy 2.x, Alembic, psycopg 3, pwdlib/Argon2, pytest, HTTPX, Ruff, mypy, SQLite for fast tests, PostgreSQL for integration evidence.

**Spec:** `docs/superpowers/specs/2026-08-25-nas-centralized-app-design.md`

## Global Constraints

- All teachers can view and edit all live records; authorization is still evaluated for every request.
- Teachers can trash and restore records; only admins can permanently delete and a non-empty reason is mandatory.
- API keys, passwords, cookies, CSRF tokens, form bodies, and full student content must not enter logs or audit metadata.
- UUIDs are internal identifiers; visible search uses name, grade, recommended class, date, batch, creator, generation state, and recycle state.
- `version` is non-null and every stale update returns HTTP 409; silent last-write-wins is forbidden.
- Audit events are append-only from the runtime role's perspective.
- Production secrets are read from files and never committed, baked into images, or printed by config diagnostics.
- The app is same-origin; do not enable wildcard credentialed CORS.
- Existing GitHub Pages behavior must remain unchanged throughout this plan.

---

## Locked File Structure

```text
server/
  pyproject.toml
  uv.lock
  alembic.ini
  alembic/
    env.py
    versions/0001_initial_schema.py
  src/makerseed_app/
    __init__.py
    main.py                 # application factory and router registration
    config.py               # validated settings and secret-file loading
    database.py             # engine/session lifecycle and transaction dependency
    errors.py               # stable API error codes and handlers
    models/
      __init__.py
      base.py
      identity.py           # User and Session
      records.py            # Batch, Student, Evaluation, EvaluationVersion
      audit.py              # AuditEvent
      generation.py         # GenerationRecord for the reporting plan
      imports.py            # EmergencyImport for the frontend plan
    schemas/
      auth.py
      records.py
      admin.py
    security/
      passwords.py
      sessions.py
      csrf.py
      rate_limit.py
    services/
      audit.py
      records.py
      users.py
    api/
      auth.py
      records.py
      admin.py
  tests/
    conftest.py
    test_health.py
    test_config.py
    test_auth.py
    test_records.py
    test_search.py
    test_conflicts.py
    test_recycle_bin.py
    test_admin.py
    test_audit.py
```

## Stable API Contracts

```text
POST   /api/auth/login
POST   /api/auth/logout
GET    /api/session
GET    /api/evaluations
POST   /api/batches
POST   /api/batches/{batch_id}/evaluations
GET    /api/evaluations/{evaluation_id}/editor
PUT    /api/evaluations/{evaluation_id}
POST   /api/evaluations/{evaluation_id}/trash
POST   /api/evaluations/{evaluation_id}/restore
DELETE /api/evaluations/{evaluation_id}
GET    /api/admin/users
POST   /api/admin/users
PATCH  /api/admin/users/{user_id}
GET    /api/admin/audit
GET    /api/health
```

An editor response uses this stable shape:

```json
{
  "evaluation_id": "uuid",
  "version": 3,
  "batch": {"id": "uuid", "date": "2026-08-25", "teacher": "李老师", "fill_date": "2026-08-25"},
  "student": {"id": "uuid", "name": "张三", "grade": "三年级", "slot": "批次1 · 上午场"},
  "payload": {"schema_version": 1, "mods": [], "rates": [0, 0, 0, 0, 0], "skills": []},
  "updated_at": "2026-08-25T12:00:00Z",
  "updated_by": {"id": "uuid", "display_name": "李老师"}
}
```

An update request uses:

```json
{
  "version": 3,
  "student": {"name": "张三", "grade": "三年级", "slot": "批次1 · 上午场"},
  "payload": {"schema_version": 1, "mods": ["乐高搭建"], "rates": [4, 3, 4, 5, 3], "skills": []}
}
```

## Task 1: Reproducible Python Package and Safe App Factory

**Files:**
- Create: `server/pyproject.toml`
- Create: `server/src/makerseed_app/__init__.py`
- Create: `server/src/makerseed_app/config.py`
- Create: `server/src/makerseed_app/errors.py`
- Create: `server/src/makerseed_app/main.py`
- Create: `server/tests/conftest.py`
- Create: `server/tests/test_health.py`
- Create: `server/tests/test_config.py`

**Interfaces:**
- Consumes: environment variables prefixed `MKSEED_` and optional secret files.
- Produces: `Settings`, `load_secret(path: Path) -> str`, and `create_app(settings: Settings | None = None) -> FastAPI`.

- [x] **Step 1: Write failing health and production-secret tests**

```python
def test_health_discloses_only_status_and_version(client):
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "test"}

def test_production_rejects_missing_secret_files(tmp_path):
    with pytest.raises(ValueError, match="secret file"):
        Settings(environment="production", secrets_dir=tmp_path)
```

- [x] **Step 2: Run the focused tests and verify the package does not exist**

Run: `uv run --project server pytest server/tests/test_health.py server/tests/test_config.py -q`

Expected: collection fails because `makerseed_app` is not importable.

- [x] **Step 3: Create the package metadata and app factory**

Use Python `>=3.12,<3.13`. Add runtime dependencies `fastapi`, `uvicorn[standard]`, `sqlalchemy>=2,<2.1`, `psycopg[binary]>=3,<4`, `alembic>=1,<2`, `pydantic-settings>=2,<3`, `pwdlib[argon2]>=0.2,<1`, `python-multipart>=0.0.20,<1`, `reportlab>=4,<5`, and `pillow>=11,<13`. Add development dependencies `pytest`, `pytest-asyncio`, `httpx`, `ruff`, and `mypy`, then generate `server/uv.lock` with `uv lock --project server`.

`Settings` must default to `environment="development"`, `app_version="dev"`, `database_url="sqlite+pysqlite:///:memory:"`, `session_cookie_name="mkseed_session"`, and `csrf_cookie_name="mkseed_csrf"`. Production validation requires `database_url`, `session_secret`, and `bootstrap_secret` to come from files under `secrets_dir`.

- [x] **Step 4: Implement stable JSON errors and the health route**

`errors.py` must expose `ApiError(code: str, message: str, status_code: int, details: dict | None)` and return:

```json
{"error":{"code":"stable_code","message":"Chinese-safe message","details":{}}}
```

The health route must not test or disclose user counts, paths, database URLs, hostnames, or secret state.

- [x] **Step 5: Run quality checks**

Run:

```powershell
uv sync --project server --all-groups
uv run --project server pytest server/tests/test_health.py server/tests/test_config.py -q
uv run --project server ruff check server
uv run --project server mypy server/src
```

Expected: all commands exit 0.

- [x] **Step 6: Commit the independently working skeleton**

Stage only `server/pyproject.toml`, `server/uv.lock`, `server/src/makerseed_app/{__init__,config,errors,main}.py`, and the two tests. Commit with Lore trailers recording the production secret-file constraint and executed checks.

## Task 2: Database Models and Initial Migration

**Files:**
- Create: `server/src/makerseed_app/database.py`
- Create: `server/src/makerseed_app/models/base.py`
- Create: `server/src/makerseed_app/models/identity.py`
- Create: `server/src/makerseed_app/models/records.py`
- Create: `server/src/makerseed_app/models/audit.py`
- Create: `server/src/makerseed_app/models/generation.py`
- Create: `server/src/makerseed_app/models/imports.py`
- Create: `server/src/makerseed_app/models/__init__.py`
- Create: `server/alembic.ini`
- Create: `server/alembic/env.py`
- Create: `server/alembic/versions/0001_initial_schema.py`
- Create: `server/tests/test_models.py`

**Interfaces:**
- Consumes: `Settings.database_url`.
- Produces: `Base`, `build_engine(settings)`, `session_scope()`, `get_db()`, and the nine tables named in the design.

- [x] **Step 1: Write the failing schema test**

```python
def test_initial_schema_contains_required_tables(engine):
    Base.metadata.create_all(engine)
    names = set(inspect(engine).get_table_names())
    assert names == {
        "users", "sessions", "batches", "students", "evaluations",
        "evaluation_versions", "generation_records", "audit_events",
        "emergency_imports",
    }
```

- [x] **Step 2: Run it and verify the models are absent**

Run: `uv run --project server pytest server/tests/test_models.py -q`

Expected: import or assertion failure naming missing tables.

- [x] **Step 3: Implement focused declarative models**

Use UUID primary keys, timezone-aware timestamps, non-null `version` on `evaluations`, and `JSON().with_variant(JSONB, "postgresql")` for payload/snapshot metadata. `students.name`, `students.grade`, `batches.event_date`, `batches.display_name`, `evaluations.recommended_class`, `evaluations.deleted_at`, `evaluations.updated_by_id`, and `generation_records.status` must be separately indexed.

`AuditEvent.target_id` is a plain UUID value rather than a foreign key so a deletion tombstone survives permanent deletion. `Session.token_hash` is unique and stores SHA-256 only. `EvaluationVersion` stores a complete immutable snapshot for every successful update.

- [x] **Step 4: Create an explicit Alembic migration**

The migration must create all indexes and constraints, including:

```python
sa.CheckConstraint("version >= 1", name="ck_evaluations_version_positive")
sa.CheckConstraint("role IN ('teacher', 'admin')", name="ck_users_role")
sa.CheckConstraint(
    "status IN ('queued','running','completed','failed')",
    name="ck_generation_records_status",
)
```

Do not use `Base.metadata.create_all()` in production startup.

- [x] **Step 5: Verify model and migration parity**

Run:

```powershell
uv run --project server pytest server/tests/test_models.py -q
uv run --project server alembic -c server/alembic.ini upgrade head
uv run --project server alembic -c server/alembic.ini current
```

Expected: tests pass and Alembic reports `0001_initial_schema (head)` against the test database.

- [x] **Step 6: Commit the schema**

Stage the database, model, migration, and model-test files. The commit must state that PostgreSQL-specific grants are deferred to the operations plan but schema behavior is covered now.

## Task 3: Passwords, Sessions, CSRF, and Login Throttling

**Files:**
- Create: `server/src/makerseed_app/schemas/auth.py`
- Create: `server/src/makerseed_app/security/passwords.py`
- Create: `server/src/makerseed_app/security/sessions.py`
- Create: `server/src/makerseed_app/security/csrf.py`
- Create: `server/src/makerseed_app/security/rate_limit.py`
- Create: `server/src/makerseed_app/api/auth.py`
- Create: `server/src/makerseed_app/services/audit.py`
- Create: `server/tests/test_auth.py`

**Interfaces:**
- Consumes: `User`, `Session`, database transaction dependency, and stable API errors.
- Produces: `hash_password`, `verify_password`, `create_session`, `require_user`, `require_admin`, `require_csrf`, and auth routes.

- [x] **Step 1: Write failing authentication boundary tests**

```python
def test_login_sets_secure_session_and_csrf_cookies(client, teacher):
    response = client.post("/api/auth/login", json={"username": "teacher", "password": "correct horse battery staple"})
    assert response.status_code == 200
    assert "HttpOnly" in response.headers.get_list("set-cookie")[0]
    assert "SameSite=lax" in response.headers.get_list("set-cookie")[0]

def test_state_change_without_csrf_is_rejected(authenticated_teacher_client):
    response = authenticated_teacher_client.post("/api/auth/logout")
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "csrf_failed"
```

Also test wrong-password audit redaction, five-failure lockout, expired sessions, disabled users, logout invalidation, and admin role rejection for a teacher.

- [x] **Step 2: Run tests and confirm auth modules are missing**

Run: `uv run --project server pytest server/tests/test_auth.py -q`

Expected: import/route failures.

- [x] **Step 3: Implement password and opaque-session primitives**

Use `PasswordHash.recommended()` from `pwdlib`. Generate 32 random bytes for the session token, store only `sha256(token).hexdigest()`, and place the raw token only in the `mkseed_session` HttpOnly cookie. Generate an independent CSRF token, place it in a readable `mkseed_csrf` cookie, and require exact equality with `X-CSRF-Token` for POST/PUT/PATCH/DELETE.

Production cookies use `Secure`; tests may explicitly set `secure_cookies=False`. Both cookies use `SameSite=Lax`, an explicit path `/`, and bounded expiry.

- [x] **Step 4: Implement persistent account lockout and audit redaction**

After five consecutive failures, set `locked_until` for 15 minutes. Successful login clears the counter. Login audit metadata may include normalized username, source IP hash, outcome, and internal user ID; it must never include the submitted password, token, Cookie, Authorization header, or request body.

- [x] **Step 5: Register routes and run focused security tests**

Run:

```powershell
uv run --project server pytest server/tests/test_auth.py -q
uv run --project server ruff check server/src/makerseed_app/security server/src/makerseed_app/api/auth.py
```

Expected: all tests pass and lint exits 0.

- [x] **Step 6: Commit authentication**

Stage only the auth schema, security modules, auth route, audit service, and auth tests. Record cookie, CSRF, lockout, and redaction evidence in the commit trailers.

## Task 4: Shared Records, Search, Version History, and 409 Conflicts

**Files:**
- Create: `server/src/makerseed_app/schemas/records.py`
- Create: `server/src/makerseed_app/services/records.py`
- Create: `server/src/makerseed_app/api/records.py`
- Create: `server/tests/test_records.py`
- Create: `server/tests/test_search.py`
- Create: `server/tests/test_conflicts.py`

**Interfaces:**
- Consumes: authenticated users, database sessions, models, and `write_audit_event`.
- Produces: list/create/editor/update APIs and `update_evaluation(db, evaluation_id, expected_version, update, actor)`.

- [x] **Step 1: Write failing shared-access and search tests**

```python
def test_teacher_can_read_and_update_another_teachers_record(client_for_teacher_b, evaluation_by_teacher_a, csrf_b):
    get_response = client_for_teacher_b.get(f"/api/evaluations/{evaluation_by_teacher_a.id}/editor")
    assert get_response.status_code == 200
    body = get_response.json()
    body["payload"]["obs1"] = "补充后的课堂具体表现"
    put_response = client_for_teacher_b.put(
        f"/api/evaluations/{evaluation_by_teacher_a.id}",
        headers={"X-CSRF-Token": csrf_b},
        json={"version": body["version"], "student": body["student"], "payload": body["payload"]},
    )
    assert put_response.status_code == 200

def test_partial_chinese_name_search(client, evaluation_named_zhang_san):
    response = client.get("/api/evaluations", params={"q": "张"})
    assert [row["student_name"] for row in response.json()["items"]] == ["张三"]
```

- [x] **Step 2: Write the stale-version test**

```python
def test_stale_update_returns_409_and_keeps_newer_data(client_a, client_b, evaluation, csrf_a, csrf_b):
    first = client_a.get(f"/api/evaluations/{evaluation.id}/editor").json()
    stale = client_b.get(f"/api/evaluations/{evaluation.id}/editor").json()
    first["payload"]["note"] = "A 的保存"
    assert client_a.put(f"/api/evaluations/{evaluation.id}", headers={"X-CSRF-Token": csrf_a}, json={"version": first["version"], "student": first["student"], "payload": first["payload"]}).status_code == 200
    stale["payload"]["note"] = "B 的旧版本"
    response = client_b.put(f"/api/evaluations/{evaluation.id}", headers={"X-CSRF-Token": csrf_b}, json={"version": stale["version"], "student": stale["student"], "payload": stale["payload"]})
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "version_conflict"
```

- [x] **Step 3: Run focused tests and confirm routes are absent**

Run: `uv run --project server pytest server/tests/test_records.py server/tests/test_search.py server/tests/test_conflicts.py -q`

Expected: 404/import failures.

- [x] **Step 4: Implement schemas and version-qualified writes**

Validate `payload.schema_version == 1`, exactly five rates in `0..5`, three skill slots, bounded text lengths, and required name. Perform update as one transaction that:

1. selects the current evaluation;
2. compares the submitted version;
3. inserts the pre-change snapshot into `evaluation_versions`;
4. updates student searchable columns and evaluation payload;
5. increments version;
6. inserts an audit event;
7. commits once.

Map SQLAlchemy stale-row detection to `ApiError("version_conflict", ..., 409)` and return the current server version in `details.current_version`.

- [x] **Step 5: Implement indexed list filters and stable pagination**

Support `q`, `date_from`, `date_to`, `batch_id`, `grade`, `recommended_class`, `created_by`, `generation_status`, `trashed`, `limit<=100`, and opaque `cursor`. Sort by `updated_at DESC, id DESC` to avoid duplicate/omitted rows between pages.

- [x] **Step 6: Run record tests and static checks**

Run:

```powershell
uv run --project server pytest server/tests/test_records.py server/tests/test_search.py server/tests/test_conflicts.py -q
uv run --project server ruff check server/src/makerseed_app/schemas/records.py server/src/makerseed_app/services/records.py server/src/makerseed_app/api/records.py
```

Expected: all commands pass.

- [x] **Step 7: Commit centralized records**

Stage the three implementation modules and three test files. The commit must record shared-teacher access and 409 conflict evidence.

## Task 5: Recycle Bin, Permanent Deletion, Admin Accounts, and Audit Query

**Files:**
- Create: `server/src/makerseed_app/schemas/admin.py`
- Create: `server/src/makerseed_app/services/users.py`
- Create: `server/src/makerseed_app/api/admin.py`
- Modify: `server/src/makerseed_app/services/records.py`
- Modify: `server/src/makerseed_app/api/records.py`
- Create: `server/tests/test_recycle_bin.py`
- Create: `server/tests/test_admin.py`
- Create: `server/tests/test_audit.py`

**Interfaces:**
- Consumes: role dependencies, record service, user/session models, and audit service.
- Produces: trash/restore/permanent-delete behavior, account management, and paginated audit access.

- [x] **Step 1: Write failing permission-matrix tests**

```python
@pytest.mark.parametrize("role,expected", [("teacher", 403), ("admin", 204)])
def test_only_admin_can_permanently_delete(role_client, role, expected, evaluation, csrf_for_role):
    response = role_client.delete(
        f"/api/evaluations/{evaluation.id}",
        headers={"X-CSRF-Token": csrf_for_role},
        json={"reason": "监护人书面要求删除"},
    )
    assert response.status_code == expected

def test_teacher_can_trash_and_restore(shared_teacher_client, evaluation, csrf):
    assert shared_teacher_client.post(f"/api/evaluations/{evaluation.id}/trash", headers={"X-CSRF-Token": csrf}).status_code == 200
    assert shared_teacher_client.post(f"/api/evaluations/{evaluation.id}/restore", headers={"X-CSRF-Token": csrf}).status_code == 200
```

Also test empty deletion reason rejection, audit tombstone survival, disabled-user session invalidation, teacher denial from admin routes, and audit body redaction.

- [x] **Step 2: Run focused tests and verify failure**

Run: `uv run --project server pytest server/tests/test_recycle_bin.py server/tests/test_admin.py server/tests/test_audit.py -q`

Expected: missing route/service failures.

- [x] **Step 3: Implement soft-delete and restore transactions**

Trash sets `deleted_at`, `deleted_by_id`, and increments `version`; restore clears deletion fields and increments `version`. Both preserve history and write audit in the same transaction. Live list defaults to `trashed=false`; recycle list uses `trashed=true`.

- [x] **Step 4: Implement admin permanent deletion without destroying audit**

Validate a trimmed reason length of 4..500. Insert the audit tombstone first with target UUID, student display label reduced to the minimum useful value, actor, timestamp, and reason; delete generated-file database rows, evaluation versions, evaluation, and orphan student rows in one transaction. File deletion is delegated to the reporting plan's storage service and must fail closed if a path is outside the project report root.

- [x] **Step 5: Implement account and audit APIs**

Admins may create teacher/admin accounts, change display name/role/status, and reset passwords. Disabling a user revokes all sessions in the same transaction. Audit queries support actor, action, target ID, and date filters; response metadata excludes form bodies and secrets.

- [x] **Step 6: Run the full foundation suite**

Run:

```powershell
uv run --project server pytest server/tests -q
uv run --project server ruff check server
uv run --project server mypy server/src
```

Expected: all commands exit 0.

- [x] **Step 7: Commit the complete foundation phase**

Stage the admin/recycle/audit changes and tests. Record the permission matrix, session revocation, tombstone, full pytest, Ruff, and mypy results in Lore trailers.

## Task 6: Foundation Evidence and Plan Gate

**Files:**
- Create: `docs/verification/foundation-data.md`
- Modify: `docs/superpowers/plans/2026-08-25-nas-foundation-data-plan.md`

**Interfaces:**
- Consumes: all Task 1-5 test output.
- Produces: a reviewable phase verdict and checked task boxes.

- [ ] **Step 1: Run the clean-room command set**

Run from a fresh `server/.venv` created by `uv sync --project server --all-groups`:

```powershell
uv run --project server pytest server/tests -q
uv run --project server ruff check server
uv run --project server mypy server/src
pwsh -NoProfile -File tests/verify-static-site.ps1
```

Expected: every command passes; the existing static Pages verifier proves no regression at this stage.

- [ ] **Step 2: Record exact evidence**

`docs/verification/foundation-data.md` must include commit SHA, dependency lock hash, test counts, commands, exit codes, SQLite limitation, and a clear statement that PostgreSQL/NAS behavior remains unproven until the operations plan.

- [ ] **Step 3: Mark only completed checkboxes and commit evidence**

Update this plan's executed boxes based on actual output. Commit the evidence and plan status with `Not-tested: PostgreSQL and Synology hardware are verified in the operations phase` unless that evidence already exists.

