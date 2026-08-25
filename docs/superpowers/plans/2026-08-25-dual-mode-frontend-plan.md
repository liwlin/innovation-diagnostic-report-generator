# Dual-Mode Pages and NAS Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the current GitHub Pages local-only emergency workflow while adding a same-source NAS login, searchable shared dashboard, API-backed editor, recycle bin, admin tools, audit view, generation history, and manual emergency JSON import.

**Architecture:** GitHub Pages continues to enter the existing report HTML in `local` mode. The NAS serves a small framework-free shell for authenticated list/admin workflows and opens the same report HTML in `api` editor mode. A tested repository bridge confines persistence differences: local mode writes only the established browser keys, while API mode loads one evaluation and debounces versioned saves without retaining a database replica.

**Tech Stack:** Existing DCLogic/support.js runtime, browser JavaScript, standards-based HTML/CSS, Node.js built-in tests, FastAPI static serving and import APIs, pytest, browser automation through the available Browser tooling.

**Spec:** `docs/superpowers/specs/2026-08-25-nas-centralized-app-design.md`

## Global Constraints

- GitHub Pages never calls NAS APIs and never receives NAS URLs, cookies, secrets, or centralized data.
- NAS business data is not persisted wholesale to `localStorage`; API Key remains browser-only and is excluded from JSON export/import.
- Existing form content, report view, validation, AI provider call, PDF/PNG local export, filename semantics, and local history remain available on Pages.
- All NAS mutation requests send `X-CSRF-Token` and surface server failure; no local-success fallback is allowed in API mode.
- API mode auto-save visibly reports saving, saved, failed, and conflict states.
- HTTP 409 stops further auto-save until the teacher reloads or explicitly resolves the conflict.
- Text from users and API responses is inserted with `textContent` or existing React interpolation; never concatenate it into HTML.
- Emergency import is preview/confirm/manual and idempotent by SHA-256; automatic two-way sync is forbidden.
- The shell and editor remain usable at 1366×768 and on current Chrome/Edge desktop browsers.

---

## Locked File Structure

```text
shared/
  runtime-config.js
  editor-repository.js
nas-web/
  index.html
  app.css
  api-client.js
  app.js
  views.js
tests/js/
  runtime-config.test.js
  editor-repository.test.js
  api-client.test.js
server/src/makerseed_app/
  static_files.py
  api/imports.py
  api/events.py
  services/imports.py
  schemas/imports.py
server/tests/
  test_static_modes.py
  test_emergency_import.py
  test_ai_audit_event.py
tests/browser/
  dual-mode.spec.js
```

## Stable Browser Interfaces

```javascript
MakerSeedRuntime.getConfig(location) -> {
  storageMode: "local" | "api",
  apiBaseUrl: string,
  appVersion: string,
  commitSha: string
}

MakerSeedEditorRepository.create({config, fetchImpl, storage, onStatus}) -> repository
repository.load({evaluationId}) -> Promise<EditorDocument>
repository.scheduleSave(editorDocument) -> void
repository.flush() -> Promise<EditorDocument>
repository.dispose() -> void
```

The NAS shell API client exposes:

```javascript
api.getSession()
api.login(username, password)
api.logout()
api.listEvaluations(filters)
api.trashEvaluation(id)
api.restoreEvaluation(id)
api.permanentlyDeleteEvaluation(id, reason)
api.listUsers()
api.createUser(input)
api.updateUser(id, input)
api.listAudit(filters)
api.previewEmergencyImport(file)
api.confirmEmergencyImport(file, sha256)
```

## Task 1: Runtime Mode and Tested Persistence Repository

**Files:**
- Create: `shared/runtime-config.js`
- Create: `shared/editor-repository.js`
- Create: `tests/js/runtime-config.test.js`
- Create: `tests/js/editor-repository.test.js`
- Modify: `科创方向诊断报告生成器.dc.html`

**Interfaces:**
- Consumes: browser location, `window.__MKSEED_RUNTIME__`, existing localStorage keys, and record API.
- Produces: `MakerSeedRuntime` and `MakerSeedEditorRepository` globals with CommonJS exports for Node tests.

- [x] **Step 1: Write failing runtime-config tests**

```javascript
test('Pages defaults to local mode without an injected config', () => {
  assert.deepEqual(runtime.getConfig({search: '', origin: 'https://liwlin.github.io'}).storageMode, 'local');
});

test('api mode requires same-origin empty apiBaseUrl', () => {
  assert.throws(() => runtime.validate({storageMode: 'api', apiBaseUrl: 'https://other.example'}), /same-origin/);
});
```

- [x] **Step 2: Write failing repository behavior tests**

Test that local mode reads/writes `mkseed_diag_v3`, API mode never calls `storage.setItem` with business data, API saves debounce to one PUT, `flush()` waits for the response, successful save adopts the returned version, 401 emits `signed_out`, 409 emits `conflict` and disables new saves, and disposal cancels pending timers.

- [x] **Step 3: Run Node tests and verify modules are missing**

Run: `node --test tests/js/runtime-config.test.js tests/js/editor-repository.test.js`

Expected: missing module failures.

- [x] **Step 4: Implement UMD modules without a bundler**

`runtime-config.js` defaults to local mode. API mode can only be injected by the NAS response and requires same-origin relative API URLs. `editor-repository.js` keeps the current synchronous local behavior and an API implementation with a 700 ms debounce, one in-flight request, queued latest snapshot, CSRF header, and terminal conflict state.

- [x] **Step 5: Add a narrow editor integration seam**

Load both scripts before the DC component script. In local mode, `_load()` and `_persist()` continue current behavior. In API mode, constructor state starts in `loading`; `componentDidMount` loads `evaluation_id` from a UUID-only query parameter; `_persist` sends the current student/evaluation document through the repository. The history and multi-batch controls are hidden in API editor mode because the NAS shell owns those lists.

Status callbacks map exactly to Chinese UI states: `正在保存…`, `已保存`, `保存失败，请检查网络后重试`, `记录已被其他老师修改，请重新加载`, and `登录已失效，请重新登录`.

- [x] **Step 6: Run Node and Pages regression tests**

Run:

```powershell
node --test tests/js/runtime-config.test.js tests/js/editor-repository.test.js
pwsh -NoProfile -File tests/verify-static-site.ps1
```

Expected: tests pass and Pages static runtime files remain reachable.

- [x] **Step 7: Commit the dual-mode persistence boundary**

Record local-mode compatibility, no API-mode business localStorage, debounce, CSRF, and 409 behavior.

## Task 2: NAS Same-Origin Static Shell, Login, Search, and Record Navigation

**Files:**
- Create: `nas-web/index.html`
- Create: `nas-web/app.css`
- Create: `nas-web/api-client.js`
- Create: `nas-web/views.js`
- Create: `nas-web/app.js`
- Create: `tests/js/api-client.test.js`
- Create: `server/src/makerseed_app/static_files.py`
- Create: `server/tests/test_static_modes.py`
- Modify: `server/src/makerseed_app/main.py`

**Interfaces:**
- Consumes: foundation APIs, version metadata, CSRF cookie, and static source files.
- Produces: `/`, `/editor`, `/static/*`, strict shell rendering, login, shared list, filters, create flow, and editor navigation.

- [ ] **Step 1: Write failing API-client tests**

```javascript
test('mutations send csrf and credentials', async () => {
  const calls = [];
  const client = createApiClient({fetchImpl: fakeFetch(calls), cookieReader: () => 'csrf-token'});
  await client.trashEvaluation('00000000-0000-0000-0000-000000000001');
  assert.equal(calls[0].options.credentials, 'same-origin');
  assert.equal(calls[0].options.headers['X-CSRF-Token'], 'csrf-token');
});
```

Also test stable API error extraction, URLSearchParams encoding, no HTML insertion helpers, and 401 redirect events.

- [ ] **Step 2: Write failing static-mode tests**

Assert `/` returns NAS shell with `storageMode:"api"`, `/editor` returns the existing report editor with API runtime injection, static paths use `nosniff`, and `/api/*` is never shadowed by static fallback.

- [ ] **Step 3: Run tests and verify files/routes are absent**

Run:

```powershell
node --test tests/js/api-client.test.js
uv run --project server pytest server/tests/test_static_modes.py -q
```

Expected: missing module/404 failures.

- [ ] **Step 4: Build semantic login and dashboard views**

The shell has no inline event attributes. `views.js` builds DOM nodes through `createElement` and `textContent`. Login posts credentials, then the dashboard loads all records available to the authenticated teacher. Filters include name text, date range, batch, grade, recommended class, creator, generation status, and recycle state. Each result shows visible name, batch/date, last editor/time, generation state, and an Edit button linking to `/editor?evaluation_id=<uuid>`.

- [ ] **Step 5: Serve mode-specific static responses safely**

`static_files.py` serves the shell and editor without directory listings or arbitrary file paths. Add `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`, `X-Frame-Options: DENY`, and a shell CSP limited to self. The legacy editor receives the narrow CSP exception required by the existing inline DC template and no third-party script origins.

- [ ] **Step 6: Run frontend and backend tests**

Run:

```powershell
node --test tests/js/api-client.test.js
uv run --project server pytest server/tests/test_static_modes.py -q
uv run --project server ruff check server/src/makerseed_app/static_files.py
```

Expected: all pass.

- [ ] **Step 7: Commit login/search shell**

Record same-origin, security-header, text-escaping, keyboard navigation, and search evidence.

## Task 3: API Editor Load, Autosave, Generation, and Conflict UX

**Files:**
- Modify: `科创方向诊断报告生成器.dc.html`
- Modify: `shared/editor-repository.js`
- Modify: `nas-web/app.js`
- Modify: `nas-web/views.js`
- Create: `tests/js/editor-integration.test.js`

**Interfaces:**
- Consumes: editor document API, generation API, repository status events, and current DC methods.
- Produces: one-record editor lifecycle, visible save state, conflict recovery, return-to-list, and generation history/download controls.

- [ ] **Step 1: Write failing integration-state tests**

Test `EditorDocument -> current batch/student state` mapping and reverse mapping without dropping any current fields: `mods`, `customMods`, `chart`, five `rates`, three `skills`, `obs1`, `obs2`, direction/custom direction, reason, class selection, internal fields, and `generated`.

Test that a 409 freezes saves and renders both the local unsaved timestamp and server current version, while `重新加载服务器版本` performs a new GET before editing resumes.

- [ ] **Step 2: Run the Node test and verify mapping is absent**

Run: `node --test tests/js/editor-integration.test.js`

Expected: missing exports or assertion failures.

- [ ] **Step 3: Implement lossless mappings and lifecycle**

The API editor displays a loading state until GET succeeds, blocks form actions on 401/404, and calls `flush()` before navigation or report generation. It never marks `generated=true` until the server accepts a generation request. Browser unload warning appears only while a save is queued, in flight, failed, or conflicted.

- [ ] **Step 4: Add generation history and downloads**

The editor lists generation ID, time, actor, status, renderer version, and four artifact links. Failed jobs show sanitized error and an authenticated retry action. Existing Pages buttons continue browser print/image behavior; NAS mode replaces them with server generation actions.

- [ ] **Step 5: Run integration and Pages tests**

Run:

```powershell
node --test tests/js/editor-integration.test.js tests/js/editor-repository.test.js
pwsh -NoProfile -File tests/verify-static-site.ps1
```

Expected: all pass.

- [ ] **Step 6: Commit the API-backed editor**

Record field-mapping coverage, save-state behavior, conflict freeze/reload, server-generation boundary, and Pages regression.

## Task 4: Recycle Bin, Admin Users, Audit, and Logout

**Files:**
- Modify: `nas-web/index.html`
- Modify: `nas-web/app.css`
- Modify: `nas-web/app.js`
- Modify: `nas-web/views.js`
- Create: `tests/js/admin-views.test.js`

**Interfaces:**
- Consumes: role from `/api/session`, recycle/admin/audit APIs, and API client.
- Produces: role-aware navigation, recycle/restore, reasoned permanent delete, account management, audit filters, and complete logout cleanup.

- [ ] **Step 1: Write failing role and destructive-action tests**

Test that teacher DOM never contains permanent-delete/user-management controls, admin permanent deletion cannot call the API without a trimmed reason of at least four characters, restore appears for both roles, and logout clears browser-only AI configuration for NAS mode before redirecting to login.

- [ ] **Step 2: Run Node tests and verify missing views**

Run: `node --test tests/js/admin-views.test.js`

Expected: missing module/assertion failures.

- [ ] **Step 3: Implement recycle and admin workflows**

Use two-step destructive confirmation: select record, show student/batch/generation count and backup-retention warning, then require a typed reason. User management supports create, role/status change, password reset, and never renders password hashes or session data. Audit table supports actor/action/target/date filters and displays metadata as escaped key/value text.

- [ ] **Step 4: Implement logout privacy cleanup**

Flush pending record saves, call logout with CSRF, remove only NAS-mode browser AI keys and transient UI state, and leave Pages local business data untouched.

- [ ] **Step 5: Run Node tests and keyboard/static checks**

Run: `node --test tests/js/admin-views.test.js tests/js/api-client.test.js`

Expected: all pass.

- [ ] **Step 6: Commit role-aware management UI**

Record teacher/admin DOM boundary, reason validation, backup warning, escaping, and logout cleanup.

## Task 5: Emergency JSON Export, Preview, Confirm, and AI Audit Metadata

**Files:**
- Create: `server/src/makerseed_app/schemas/imports.py`
- Create: `server/src/makerseed_app/services/imports.py`
- Create: `server/src/makerseed_app/api/imports.py`
- Create: `server/src/makerseed_app/api/events.py`
- Create: `server/tests/test_emergency_import.py`
- Create: `server/tests/test_ai_audit_event.py`
- Modify: `科创方向诊断报告生成器.dc.html`
- Modify: `nas-web/app.js`
- Modify: `nas-web/views.js`

**Interfaces:**
- Consumes: current local batches/class list/promo, admin auth, multipart JSON file, normalized record service, and audit service.
- Produces: Pages export without secrets, admin preview/confirm import, idempotent hash, and sanitized AI-use audit.

- [ ] **Step 1: Write failing export-content test**

The browser test exports a representative local workspace and asserts the JSON includes `schema_version`, `exported_at`, `source_version`, `batches`, `class_list`, and `promo_text`; it must not contain `apiKey`, `Authorization`, NAS URL, cookies, or any key from `mkseed_diag_aicfg_v1`.

- [ ] **Step 2: Write failing import API tests**

```python
def test_preview_is_non_mutating(admin_client, emergency_json, csrf, db):
    before = count_evaluations(db)
    response = admin_client.post("/api/admin/imports/preview", headers={"X-CSRF-Token": csrf}, files={"file": ("emergency.json", emergency_json, "application/json")})
    assert response.status_code == 200
    assert count_evaluations(db) == before

def test_confirm_is_idempotent_by_sha256(admin_client, emergency_json, csrf):
    preview = preview_file(admin_client, emergency_json, csrf)
    first = confirm_file(admin_client, emergency_json, preview["sha256"], csrf)
    second = confirm_file(admin_client, emergency_json, preview["sha256"], csrf)
    assert first.status_code == 201
    assert second.status_code == 409
```

Also test teacher denial, 10 MiB limit, invalid JSON/schema rejection, duplicate/conflict counts, file-hash mismatch, no API-key import, and audit rows.

- [ ] **Step 3: Run tests and verify missing implementations**

Run: `uv run --project server pytest server/tests/test_emergency_import.py server/tests/test_ai_audit_event.py -q`

Expected: missing route/service failures.

- [ ] **Step 4: Implement export and two-pass import**

Preview parses and normalizes without writes, returns SHA-256 and `new/duplicate/conflict/invalid` counts plus safe row labels. Confirm reparses the uploaded bytes, recomputes the same hash, rejects an already completed hash, creates records through the standard service so versions/audits remain valid, and stores only import metadata—not API keys—in `emergency_imports`.

- [ ] **Step 5: Implement sanitized AI-use event**

NAS editor posts provider hostname, model, field key, evaluation UUID, duration, and success/failure after a browser-direct AI request. Server rejects URLs with credentials, strips query/path, bounds values, and writes audit only. No prompt, response text, or API Key is accepted by the schema.

- [ ] **Step 6: Run import, AI audit, and static regression tests**

Run:

```powershell
uv run --project server pytest server/tests/test_emergency_import.py server/tests/test_ai_audit_event.py -q
node --test tests/js/*.test.js
pwsh -NoProfile -File tests/verify-static-site.ps1
```

Expected: all pass.

- [ ] **Step 7: Commit emergency recovery behavior**

Record no-secret export, non-mutating preview, hash idempotence, conflict counts, admin-only import, and AI audit redaction.

## Task 6: End-to-End Browser Verification

**Files:**
- Create: `tests/browser/dual-mode.spec.js`
- Create: `docs/verification/dual-mode-frontend.md`
- Modify: `docs/superpowers/plans/2026-08-25-dual-mode-frontend-plan.md`

**Interfaces:**
- Consumes: running test app, seeded teacher/admin users, test database, and Browser tooling.
- Produces: screenshots, console/network verdicts, two-user conflict evidence, and Pages/NAS mode separation evidence.

- [ ] **Step 1: Start the isolated test server**

Use a temporary SQLite file and temporary report root. Bind only `127.0.0.1` on a dynamically checked free port. Seed one admin, two teachers, two batches, and named evaluations with fixture data.

- [ ] **Step 2: Verify teacher workflow in a real browser**

Log in, search `张`, edit a record created by the other teacher, wait for visible `已保存`, reload, generate reports, view history, download a fixture file, move to recycle bin, restore, and log out. Assert no relevant console errors or failed same-origin API requests.

- [ ] **Step 3: Verify two-browser conflict behavior**

Open the same evaluation in two independent browser contexts. Save in A, then save stale state in B. Prove B displays the conflict message, the server retains A, and B cannot auto-save again until reload.

- [ ] **Step 4: Verify admin-only workflow**

Log in as admin, create/disable a teacher, inspect audit, preview an emergency JSON, confirm import, trash the imported record, provide a reason, and permanently delete it. Verify the teacher context cannot see or call the corresponding admin actions.

- [ ] **Step 5: Verify Pages remains local and disconnected**

Serve the repository with the existing static server, create local data, reload it, inspect network requests to prove no `/api/` call, export emergency JSON, and verify it contains no AI key. Capture a Pages-mode screenshot.

- [ ] **Step 6: Record evidence and commit the phase gate**

Document URLs as loopback only, app commit, seeded accounts as non-secret fixture names, screenshots, console/network results, exact automation commands, and limitations. Mark only executed plan boxes and commit evidence.

