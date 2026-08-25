# NAS Reporting and File Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate immutable parent/internal PDF and PNG reports on the server with exact legacy filename semantics, safe human-readable File Station paths, persistent single-concurrency jobs, hashes, history, and authenticated downloads.

**Architecture:** A shared fixture and paired JavaScript/Python naming functions lock filename compatibility. A pure-Python ReportLab/Pillow renderer consumes an immutable evaluation snapshot, while a storage service owns path sanitization and atomic writes. PostgreSQL-backed generation records form a restart-safe queue processed by one in-process worker.

**Tech Stack:** Python 3.12, ReportLab, Pillow, SQLAlchemy, FastAPI, Node.js built-in test runner, pytest, Noto CJK production font, Poppler/pdfplumber for verification when available.

**Spec:** `docs/superpowers/specs/2026-08-25-nas-centralized-app-design.md`

## Global Constraints

- Preserve the exact existing base pattern `{name}_{date}_科创体验报告`, suffixes `_无内联` and `_含内联`, illegal-character removal, and empty fallback `科创体验报告`.
- A successful generation produces four files when internal sections are enabled: parent PDF/PNG and internal PDF/PNG.
- Internal outputs have an unmistakable internal-use mark; parent outputs contain no internal fields.
- Jobs run with concurrency 1, retry at most twice after the initial attempt, and survive app restart.
- Every generation has a new UUID and immutable input snapshot; no history file is overwritten.
- Only project report and temporary directories are writable; paths outside the configured report root fail closed.
- Files are written to a temporary sibling and atomically renamed after format and hash validation.
- Teachers may download reports; file creation/deletion remains auditable through the app.

---

## Locked File Structure

```text
shared/
  report-filename.js
  report-filename-cases.json
server/src/makerseed_app/
  domain/report_filename.py
  reports/fonts.py
  reports/layout.py
  reports/renderer.py
  reports/storage.py
  reports/jobs.py
  schemas/generations.py
  api/generations.py
server/tests/
  test_report_filename.py
  test_report_paths.py
  test_report_renderer.py
  test_generation_jobs.py
  test_generation_api.py
tests/js/report-filename.test.js
```

## Stable Interfaces

```python
def report_filename(name: str, date_label: str, variant: Literal["with", "without"] | None, pattern: str, today_compact: str | None = None) -> str: ...

@dataclass(frozen=True)
class ReportArtifact:
    variant: Literal["with", "without"]
    format: Literal["pdf", "png"]
    absolute_path: Path
    relative_path: str
    sha256: str
    size: int
    mime: str

def render_report_set(snapshot: ReportSnapshot, output_dir: Path, font_path: Path) -> list[ReportArtifact]: ...
def process_next_generation(db: Session, settings: Settings) -> UUID | None: ...
```

```text
POST /api/evaluations/{evaluation_id}/generations
GET  /api/evaluations/{evaluation_id}/generations
GET  /api/generations/{generation_id}
GET  /api/generations/{generation_id}/files/{artifact_id}
POST /api/generations/{generation_id}/retry
```

## Task 1: Cross-Language Legacy Filename Contract

**Files:**
- Create: `shared/report-filename-cases.json`
- Create: `shared/report-filename.js`
- Create: `server/src/makerseed_app/domain/report_filename.py`
- Create: `tests/js/report-filename.test.js`
- Create: `server/tests/test_report_filename.py`
- Modify: `科创方向诊断报告生成器.dc.html:1028-1036`

**Interfaces:**
- Consumes: legacy `_filename` behavior.
- Produces: `MakerSeedReportFilename.build(input)` in JS and `report_filename(...)` in Python.

- [x] **Step 1: Write a shared fixture with exact edge cases**

```json
[
  {"name":"张三","date":"8月25日","variant":"without","pattern":"{name}_{date}_科创体验报告","expected":"张三_8月25日_科创体验报告_无内联"},
  {"name":"张三","date":"8月25日","variant":"with","pattern":"{name}_{date}_科创体验报告","expected":"张三_8月25日_科创体验报告_含内联"},
  {"name":"A/B:C*D?","date":"2026/08/25","variant":null,"pattern":"{name}_{date}","expected":"ABCD_20260825"},
  {"name":"","date":"","today_compact":"20260825","variant":null,"pattern":"","expected":"学员_20260825_科创体验报告"},
  {"name":"张三","date":"8月25日","variant":null,"pattern":"////","expected":"科创体验报告"}
]
```

Add cases for quotes, angle brackets, pipe, whitespace, repeated placeholders, custom pattern, and variant `null`.

- [x] **Step 2: Write failing Node and pytest fixture consumers**

The Node test loads `shared/report-filename.js` with `require()` and asserts every fixture. The Python test calls `report_filename` with identical inputs and asserts the same expected values.

- [x] **Step 3: Run both tests and verify failure**

Run:

```powershell
node --test tests/js/report-filename.test.js
uv run --project server pytest server/tests/test_report_filename.py -q
```

Expected: missing module failures.

- [x] **Step 4: Implement both functions and delegate the HTML method**

Both implementations must replace all `{name}` and `{date}` occurrences, use `学员` and current compact date only when the corresponding value is blank, append the exact variant suffix, remove `[\\/:*?"<>|]`, trim, and then fall back to `科创体验报告`.

The existing `_filename` body becomes a thin call to `MakerSeedReportFilename.build` so Pages and NAS cannot drift.

- [x] **Step 5: Run filename and static-site regression tests**

Run:

```powershell
node --test tests/js/report-filename.test.js
uv run --project server pytest server/tests/test_report_filename.py -q
pwsh -NoProfile -File tests/verify-static-site.ps1
```

Expected: all commands pass.

- [x] **Step 6: Commit the compatibility seam**

Stage the shared fixture/functions, tests, and narrow HTML change. Record exact legacy parity and Pages verification in commit trailers.

## Task 2: Safe Human-Readable Storage and Atomic Artifacts

**Files:**
- Create: `server/src/makerseed_app/reports/storage.py`
- Create: `server/tests/test_report_paths.py`

**Interfaces:**
- Consumes: report root, batch date/name, student display name, generation timestamp, filename base, and bytes.
- Produces: `ReportStorage.resolve_generation_dir(...)`, `write_atomic(...)`, `hash_file(...)`, and `delete_generation_files(...)`.

- [x] **Step 1: Write path traversal, collision, and atomic-write tests**

```python
def test_generation_path_is_human_readable_and_inside_root(tmp_path):
    storage = ReportStorage(tmp_path)
    path = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25), batch_name="批次1", student_name="张/三", generated_at=time(19, 32, 5)
    )
    assert path.relative_to(tmp_path).as_posix() == "2026年/08月/2026-08-25_批次1/张三/19-32-05"

def test_delete_refuses_path_outside_report_root(tmp_path):
    with pytest.raises(UnsafeReportPath):
        ReportStorage(tmp_path / "reports").delete_generation_files([tmp_path / "company" / "资料.pdf"])
```

Also test Windows reserved names, `..`, Unicode whitespace, 100-character component bounds, duplicate timestamp suffix `-2`, temporary-file cleanup, and a simulated writer failure leaving no final file.

- [x] **Step 2: Run tests and verify missing implementation**

Run: `uv run --project server pytest server/tests/test_report_paths.py -q`

Expected: import failure.

- [x] **Step 3: Implement canonical path ownership**

Use `Path.resolve(strict=False)` and `candidate.is_relative_to(root.resolve())` before every write/delete. Sanitization removes legacy illegal characters plus control characters, collapses whitespace, strips leading/trailing dots, rejects `.`/`..`, and truncates without splitting Unicode code points.

`write_atomic` creates a random `.partial` sibling with mode `0600`, writes and fsyncs, validates bytes, then uses `os.replace`. It returns SHA-256, byte size, and final path.

- [x] **Step 4: Run storage tests**

Run: `uv run --project server pytest server/tests/test_report_paths.py -q`

Expected: all cases pass.

- [x] **Step 5: Commit storage isolation**

Record traversal rejection, project-root enforcement, collision handling, and atomic-write evidence.

## Task 3: Parent/Internal PDF and PNG Renderer

**Files:**
- Create: `server/src/makerseed_app/reports/fonts.py`
- Create: `server/src/makerseed_app/reports/layout.py`
- Create: `server/src/makerseed_app/reports/renderer.py`
- Create: `server/tests/fixtures/report-snapshot.json`
- Create: `server/tests/test_report_renderer.py`

**Interfaces:**
- Consumes: immutable `ReportSnapshot`, output directory, logo assets, and configured Noto CJK font.
- Produces: four validated `ReportArtifact` objects.

- [ ] **Step 1: Create a fixed Chinese fixture covering every report section**

The fixture includes five dimension scores, three skill entries, custom modules, a custom direction, long observations, recommendation, recommended class, all internal fields, teacher/date metadata, and the exact expected filename bases.

- [ ] **Step 2: Write failing renderer tests**

```python
def test_renderer_creates_four_distinct_valid_artifacts(tmp_path, report_snapshot, font_path):
    artifacts = render_report_set(report_snapshot, tmp_path, font_path)
    assert {(a.variant, a.format) for a in artifacts} == {
        ("without", "pdf"), ("without", "png"), ("with", "pdf"), ("with", "png")
    }
    assert all(a.size > 10_000 and len(a.sha256) == 64 for a in artifacts)

def test_parent_files_exclude_internal_text(rendered_parent_text):
    assert "内部跟进" not in rendered_parent_text
    assert "仅限内部使用" not in rendered_parent_text
```

Also verify PNG size is exactly `1747x2471`, PDFs open as one A4 page, internal files contain `仅限内部使用`, and all Chinese fixture strings render without replacement boxes.

- [ ] **Step 3: Run tests and verify missing renderer**

Run: `uv run --project server pytest server/tests/test_report_renderer.py -q`

Expected: import failure.

- [ ] **Step 4: Implement a shared layout model**

`layout.py` defines page constants, typography, blocks, radar/bar/dot chart drawing, text wrapping, and internal-section inclusion once. PDF and PNG backends consume the same normalized block model so content decisions cannot diverge.

`fonts.py` refuses startup when the configured CJK font is missing or unreadable. Do not silently fall back to a font that cannot render Chinese.

- [ ] **Step 5: Implement and validate both render backends**

ReportLab generates the A4 PDF. Pillow generates the legacy-compatible `1747x2471` PNG. Load existing logo assets from read-only static paths. After each render, reopen with the corresponding parser, verify page/dimensions, compute the hash, and then allow atomic publication.

- [ ] **Step 6: Run renderer and naming suites**

Run:

```powershell
uv run --project server pytest server/tests/test_report_renderer.py server/tests/test_report_filename.py -q
uv run --project server ruff check server/src/makerseed_app/reports
```

Expected: all commands pass.

- [ ] **Step 7: Commit report rendering**

Include the renderer version, fixture coverage, parent/internal separation, dimensions, and font requirement in Lore trailers.

## Task 4: Persistent Single-Concurrency Generation Worker

**Files:**
- Create: `server/src/makerseed_app/reports/jobs.py`
- Create: `server/src/makerseed_app/schemas/generations.py`
- Create: `server/tests/test_generation_jobs.py`
- Modify: `server/src/makerseed_app/main.py`

**Interfaces:**
- Consumes: `GenerationRecord`, evaluation snapshot, renderer, storage, and app lifespan.
- Produces: `enqueue_generation`, `process_next_generation`, `recover_stale_jobs`, and a single worker lifecycle.

- [ ] **Step 1: Write failing queue-state tests**

```python
def test_two_jobs_never_render_concurrently(job_service, renderer_probe):
    job_service.enqueue(two_evaluation_ids[0], actor_id)
    job_service.enqueue(two_evaluation_ids[1], actor_id)
    job_service.drain_for_test()
    assert renderer_probe.max_concurrency == 1

def test_restart_requeues_stale_running_job(db, stale_running_job):
    recover_stale_jobs(db, stale_after=timedelta(minutes=10))
    assert stale_running_job.status == "queued"
```

Also test immutable snapshot, a new generation UUID on every request, two retries then `failed`, completed-job idempotence, and partial-artifact cleanup.

- [ ] **Step 2: Run tests and verify missing queue service**

Run: `uv run --project server pytest server/tests/test_generation_jobs.py -q`

Expected: import failure.

- [ ] **Step 3: Implement transactional claim and recovery**

PostgreSQL claim uses `SELECT ... FOR UPDATE SKIP LOCKED` ordered by creation time. SQLite tests use an equivalent single-process branch. Transition `queued -> running -> completed|queued|failed` in explicit transactions. Store attempt count, started/completed timestamps, sanitized error code, renderer version, snapshot, and artifact metadata.

- [ ] **Step 4: Register exactly one lifespan worker**

The app factory starts one `asyncio` task using a bounded polling interval and stops it gracefully. It must not start in migrations, CLI commands, or tests unless the test fixture enables it.

- [ ] **Step 5: Run job tests**

Run: `uv run --project server pytest server/tests/test_generation_jobs.py -q`

Expected: all tests pass.

- [ ] **Step 6: Commit durable generation jobs**

Record concurrency, retry count, restart recovery, and immutable-snapshot evidence.

## Task 5: Generation APIs, Authorization, History, and Downloads

**Files:**
- Create: `server/src/makerseed_app/api/generations.py`
- Create: `server/tests/test_generation_api.py`
- Modify: `server/src/makerseed_app/main.py`
- Modify: `server/src/makerseed_app/services/records.py`

**Interfaces:**
- Consumes: authenticated teachers/admins, generation job service, artifacts, audit service, and safe storage.
- Produces: enqueue/status/history/retry/download routes and admin-integrated permanent file deletion.

- [ ] **Step 1: Write failing API tests**

```python
def test_teacher_can_generate_and_download_any_live_record(teacher_client, other_teachers_evaluation, csrf):
    queued = teacher_client.post(
        f"/api/evaluations/{other_teachers_evaluation.id}/generations",
        headers={"X-CSRF-Token": csrf},
    )
    assert queued.status_code == 202
    assert queued.json()["status"] == "queued"

def test_download_rejects_artifact_path_tampering(teacher_client, completed_generation):
    response = teacher_client.get(f"/api/generations/{completed_generation.id}/files/not-a-real-artifact")
    assert response.status_code == 404
```

Also test trashed-record generation rejection, invalid form rejection, retry permissions, `Content-Disposition` UTF-8 filenames, audit entries, and permanent-delete storage fail-closed behavior.

- [ ] **Step 2: Run tests and verify routes are absent**

Run: `uv run --project server pytest server/tests/test_generation_api.py -q`

Expected: 404/import failures.

- [ ] **Step 3: Implement endpoints and download safety**

Only artifacts referenced by the requested generation row may be downloaded. Re-resolve and verify the path is inside the report root before `FileResponse`. Set exact MIME, `X-Content-Type-Options: nosniff`, private/no-store caching, and RFC 5987 filename encoding.

Generation creation validates required student name, recommendation direction, and recommended class before freezing the snapshot.

- [ ] **Step 4: Integrate admin permanent deletion**

The admin deletion transaction first marks file cleanup intent; the storage service deletes only validated project paths; database deletion commits after file cleanup succeeds. Failure leaves the online record in the recycle bin and returns a stable maintenance error instead of deleting database references to undeleted files.

- [ ] **Step 5: Run the full reporting and foundation suites**

Run:

```powershell
uv run --project server pytest server/tests -q
node --test tests/js/report-filename.test.js
pwsh -NoProfile -File tests/verify-static-site.ps1
uv run --project server ruff check server
uv run --project server mypy server/src
```

Expected: every command passes.

- [ ] **Step 6: Commit reporting API completion**

Record generation authorization, safe downloads, permanent-delete file behavior, full backend suite, Node parity, and Pages regression evidence.

## Task 6: Reporting Evidence and Phase Gate

**Files:**
- Create: `docs/verification/reporting-files.md`
- Modify: `docs/superpowers/plans/2026-08-25-nas-reporting-files-plan.md`

**Interfaces:**
- Consumes: rendered fixture artifacts and Task 1-5 output.
- Produces: hashes, rendered previews, test counts, and a phase verdict.

- [ ] **Step 1: Generate the fixed report set into an isolated temporary directory**

Run a dedicated CLI command that exits unless its output root is under the OS temporary directory. Capture the four filenames, sizes, SHA-256 values, PDF page counts, PNG dimensions, and renderer version.

- [ ] **Step 2: Visually inspect parent and internal output**

Render both PDFs to PNG and inspect all four images for clipping, unreadable Chinese, internal leakage into parent output, missing watermark, or inconsistent branding. Save only non-sensitive fixture previews under `docs/verification/artifacts/reporting/`.

- [ ] **Step 3: Record exact commands and limitations**

Document that File Station ACL and NAS filesystem behavior remain unproven until the operations plan. Do not claim hardware evidence from local paths.

- [ ] **Step 4: Mark executed boxes and commit evidence**

Update only boxes supported by output and commit the plan/evidence/artifacts with Lore trailers.

