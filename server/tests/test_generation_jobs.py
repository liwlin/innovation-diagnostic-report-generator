from __future__ import annotations

import threading
import time as time_module
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from makerseed_app.models import Evaluation, GenerationRecord
from tests.support import cjk_font_path, create_evaluation


def _job_settings(tmp_path: Path):
    from makerseed_app.reports.jobs import GenerationJobSettings
    from makerseed_app.reports.renderer import RenderAssets

    return GenerationJobSettings(
        report_root=tmp_path,
        assets=RenderAssets(
            font_path=cjk_font_path(),
            logo_mark_path=Path(__file__).resolve().parents[2] / "assets" / "logo-mark.png",
            logo_lockup_path=Path(__file__).resolve().parents[2] / "assets" / "logo-lockup.png",
        ),
        renderer_version="test-renderer",
        filename_pattern="{name}_{date}_科创体验报告",
        promo_text="测试课程说明",
    )


def _artifact_renderer(snapshot, storage, output_dir, _assets):
    from makerseed_app.reports.renderer import ReportArtifact

    artifacts = []
    for variant, suffix in (("without", "无内联"), ("with", "含内联")):
        for output_format, mime in (("pdf", "application/pdf"), ("png", "image/png")):
            stored = storage.write_atomic(
                output_dir,
                f"{snapshot.student['name']}_{suffix}.{output_format}",
                f"{variant}-{output_format}".encode(),
            )
            artifacts.append(
                ReportArtifact(
                    variant=variant,
                    format=output_format,
                    path=stored.path,
                    relative_path=stored.path.relative_to(storage.root).as_posix(),
                    sha256=stored.sha256,
                    size=stored.size,
                    mime=mime,
                )
            )
    return artifacts


def _ready_evaluation(identity, *, name: str = "张三"):
    return create_evaluation(
        identity,
        name=name,
        payload_changes={
            "dir": 0,
            "obs1": "完成了齿轮结构并主动解释转向关系。",
            "obs2": "继续比较不同方案并记录结果。",
            "reason": "动手实践和创意想法表现突出。",
        },
    )


def test_enqueue_freezes_snapshot_and_every_request_gets_new_id(
    authenticated_client_factory, db_session, tmp_path: Path
):
    from makerseed_app.reports.jobs import enqueue_generation

    teacher = authenticated_client_factory()
    created = _ready_evaluation(teacher, name="快照学生")
    evaluation_id = UUID(created["evaluation_id"])
    job_settings = _job_settings(tmp_path)

    first = enqueue_generation(
        db_session,
        evaluation_id=evaluation_id,
        actor_id=teacher.user.id,
        settings=job_settings,
    )
    second = enqueue_generation(
        db_session,
        evaluation_id=evaluation_id,
        actor_id=teacher.user.id,
        settings=job_settings,
    )
    frozen_name = first.input_snapshot["student"]["name"]
    evaluation = db_session.get(Evaluation, evaluation_id)
    assert evaluation is not None
    evaluation.payload = {**evaluation.payload, "obs1": "later change"}
    db_session.commit()

    assert first.id != second.id
    assert frozen_name == "快照学生"
    assert first.input_snapshot["payload"].get("obs1", "") != "later change"
    assert first.status == second.status == "queued"


def test_restart_requeues_stale_running_job(
    authenticated_client_factory, db_session, tmp_path: Path
):
    from makerseed_app.reports.jobs import enqueue_generation, recover_stale_jobs

    teacher = authenticated_client_factory()
    created = _ready_evaluation(teacher)
    job = enqueue_generation(
        db_session,
        evaluation_id=UUID(created["evaluation_id"]),
        actor_id=teacher.user.id,
        settings=_job_settings(tmp_path),
    )
    job.status = "running"
    job.attempts = 1
    job.started_at = datetime.now(UTC) - timedelta(minutes=20)
    db_session.commit()

    recovered = recover_stale_jobs(db_session, stale_after=timedelta(minutes=10))

    assert recovered == 1
    assert job.status == "queued"
    assert job.started_at is None


def test_renderer_failure_retries_twice_then_marks_failed(
    authenticated_client_factory, db_session, tmp_path: Path
):
    from makerseed_app.reports.jobs import enqueue_generation, process_next_generation

    teacher = authenticated_client_factory()
    created = _ready_evaluation(teacher)
    job = enqueue_generation(
        db_session,
        evaluation_id=UUID(created["evaluation_id"]),
        actor_id=teacher.user.id,
        settings=_job_settings(tmp_path),
    )

    def fail_renderer(*_args, **_kwargs):
        raise RuntimeError("sensitive path must not be stored")

    for expected_status in ("queued", "queued", "failed"):
        assert (
            process_next_generation(db_session, _job_settings(tmp_path), renderer=fail_renderer)
            == job.id
        )
        db_session.expire_all()
        job = db_session.get(GenerationRecord, job.id)
        assert job is not None
        assert job.status == expected_status

    assert job.attempts == 3
    assert job.error_code == "render_failed"
    assert "sensitive path" not in (job.error_summary or "")


@pytest.mark.asyncio
async def test_worker_lock_prevents_concurrent_rendering(
    app, authenticated_client_factory, tmp_path: Path
):
    from makerseed_app.reports.jobs import GenerationWorker, enqueue_generation

    teacher = authenticated_client_factory()
    first = _ready_evaluation(teacher, name="并发甲")
    second = _ready_evaluation(teacher, name="并发乙")
    with app.state.session_factory() as session:
        for created in (first, second):
            enqueue_generation(
                session,
                evaluation_id=UUID(created["evaluation_id"]),
                actor_id=teacher.user.id,
                settings=_job_settings(tmp_path),
            )

    active = 0
    max_active = 0
    guard = threading.Lock()

    def probe_renderer(*args, **kwargs):
        nonlocal active, max_active
        with guard:
            active += 1
            max_active = max(max_active, active)
        time_module.sleep(0.05)
        try:
            return _artifact_renderer(*args, **kwargs)
        finally:
            with guard:
                active -= 1

    worker = GenerationWorker(
        app.state.session_factory,
        _job_settings(tmp_path),
        renderer=probe_renderer,
    )

    await __import__("asyncio").gather(worker.run_once(), worker.run_once())

    with app.state.session_factory() as session:
        statuses = session.scalars(
            select(GenerationRecord.status).order_by(GenerationRecord.created_at)
        ).all()
    assert statuses == ["completed", "completed"]
    assert max_active == 1


def test_app_lifespan_starts_and_stops_one_generation_worker(settings, tmp_path: Path):
    from makerseed_app.main import create_app
    from makerseed_app.models import Base

    project_root = Path(__file__).resolve().parents[2]
    worker_settings = settings.model_copy(
        update={
            "generation_worker_enabled": True,
            "generation_poll_seconds": 0.01,
            "report_root": tmp_path,
            "report_font_path": cjk_font_path(),
            "logo_mark_path": project_root / "assets" / "logo-mark.png",
            "logo_lockup_path": project_root / "assets" / "logo-lockup.png",
        }
    )
    application = create_app(worker_settings)
    Base.metadata.create_all(application.state.engine)

    with TestClient(application):
        worker = application.state.generation_worker
        task = application.state.generation_worker_task
        assert worker is not None
        assert task.done() is False

    assert task.done() is True
    Base.metadata.drop_all(application.state.engine)
    application.state.engine.dispose()
