from __future__ import annotations

import asyncio
from collections.abc import Callable
from contextlib import suppress
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import Settings
from ..database import SessionFactory
from ..errors import ApiError
from ..models import Batch, Evaluation, GenerationRecord, Student
from ..reports.layout import ReportSnapshot
from ..reports.renderer import RenderAssets, ReportArtifact, render_report_set
from ..reports.storage import ReportStorage
from ..services.audit import write_audit_event

Renderer = Callable[
    [ReportSnapshot, ReportStorage, Path, RenderAssets],
    list[ReportArtifact],
]


@dataclass(frozen=True)
class GenerationJobSettings:
    report_root: Path
    assets: RenderAssets
    renderer_version: str
    filename_pattern: str
    promo_text: str


def job_settings_from_app(settings: Settings) -> GenerationJobSettings:
    return GenerationJobSettings(
        report_root=settings.report_root,
        assets=RenderAssets(
            font_path=settings.report_font_path,
            logo_mark_path=settings.logo_mark_path,
            logo_lockup_path=settings.logo_lockup_path,
        ),
        renderer_version=settings.app_version,
        filename_pattern=settings.filename_pattern,
        promo_text=settings.promo_text,
    )


def enqueue_generation(
    db: Session,
    *,
    evaluation_id: UUID,
    actor_id: UUID,
    settings: GenerationJobSettings,
) -> GenerationRecord:
    row = db.execute(
        select(Evaluation, Student, Batch)
        .join(Student, Student.id == Evaluation.student_id)
        .join(Batch, Batch.id == Student.batch_id)
        .where(Evaluation.id == evaluation_id)
    ).one_or_none()
    if row is None:
        raise ApiError("evaluation_not_found", "未找到该记录", 404)
    evaluation, student, batch = row
    if evaluation.deleted_at is not None:
        raise ApiError("evaluation_trashed", "回收站中的记录不能生成报告", 409)
    missing: list[str] = []
    if not student.name.strip():
        missing.append("学员姓名")
    if int(evaluation.payload.get("dir", -1)) < 0:
        missing.append("推荐方向")
    if not evaluation.recommended_class.strip():
        missing.append("建议班级")
    if missing:
        raise ApiError(
            "report_not_ready",
            "请先补齐报告必填内容",
            422,
            {"missing": missing},
        )
    generation_id = uuid4()
    snapshot = {
        "evaluation_id": str(evaluation.id),
        "generation_id": str(generation_id),
        "filename_pattern": settings.filename_pattern,
        "batch": {
            "id": str(batch.id),
            "display_name": batch.display_name,
            "event_date": batch.event_date.isoformat(),
            "date_label": batch.date_label,
            "teacher_label": batch.teacher_label,
            "fill_date": batch.fill_date.isoformat(),
        },
        "student": {
            "id": str(student.id),
            "name": student.name,
            "grade": student.grade,
            "slot": student.slot,
        },
        "payload": deepcopy(evaluation.payload),
        "promo_text": settings.promo_text,
        "evaluation_version": evaluation.version,
    }
    job = GenerationRecord(
        id=generation_id,
        evaluation_id=evaluation.id,
        created_by_id=actor_id,
        status="queued",
        input_snapshot=snapshot,
        renderer_version=settings.renderer_version,
        artifact_manifest={},
    )
    db.add(job)
    write_audit_event(
        db,
        actor_user_id=actor_id,
        action="generation_queued",
        target_type="generation",
        target_id=job.id,
        target_label="",
        metadata={"evaluation_id": str(evaluation.id), "evaluation_version": evaluation.version},
    )
    db.commit()
    db.refresh(job)
    return job


def recover_stale_jobs(
    db: Session,
    *,
    stale_after: timedelta,
    now: datetime | None = None,
) -> int:
    current_time = now or datetime.now(UTC)
    cutoff = current_time - stale_after
    jobs = list(
        db.scalars(
            select(GenerationRecord).where(
                GenerationRecord.status == "running",
                GenerationRecord.started_at < cutoff,
            )
        ).all()
    )
    for job in jobs:
        job.status = "failed" if job.attempts >= 3 else "queued"
        job.started_at = None
        if job.status == "failed":
            job.completed_at = current_time
            job.error_code = "restart_retry_exhausted"
            job.error_summary = "应用重启后重试次数已用尽"
    db.commit()
    return len(jobs)


def _claim_next_job(db: Session, now: datetime) -> GenerationRecord | None:
    statement = (
        select(GenerationRecord)
        .where(GenerationRecord.status == "queued")
        .order_by(GenerationRecord.created_at, GenerationRecord.id)
        .limit(1)
    )
    if db.bind is not None and db.bind.dialect.name == "postgresql":
        statement = statement.with_for_update(skip_locked=True)
    job = db.scalar(statement)
    if job is None:
        return None
    job.status = "running"
    job.attempts += 1
    job.started_at = now
    job.completed_at = None
    job.error_code = None
    job.error_summary = None
    db.commit()
    db.refresh(job)
    return job


def _artifact_manifest(artifacts: list[ReportArtifact]) -> dict[str, object]:
    expected = {
        ("without", "pdf"),
        ("without", "png"),
        ("with", "pdf"),
        ("with", "png"),
    }
    actual = {(artifact.variant, artifact.format) for artifact in artifacts}
    if actual != expected:
        raise ValueError("renderer did not return the required four artifacts")
    return {
        "artifacts": [
            {
                "id": f"{artifact.variant}-{artifact.format}",
                "variant": artifact.variant,
                "format": artifact.format,
                "relative_path": artifact.relative_path,
                "sha256": artifact.sha256,
                "size": artifact.size,
                "mime": artifact.mime,
            }
            for artifact in artifacts
        ]
    }


def process_next_generation(
    db: Session,
    settings: GenerationJobSettings,
    *,
    renderer: Renderer = render_report_set,
    now: datetime | None = None,
) -> UUID | None:
    current_time = now or datetime.now(UTC)
    job = _claim_next_job(db, current_time)
    if job is None:
        return None
    storage = ReportStorage(settings.report_root)
    output_dir: Path | None = None
    try:
        snapshot = ReportSnapshot.from_mapping(job.input_snapshot)
        event_date = datetime.fromisoformat(str(snapshot.batch["event_date"])).date()
        output_dir = storage.resolve_generation_dir(
            event_date=event_date,
            batch_name=str(snapshot.batch["display_name"]),
            student_name=str(snapshot.student["name"]),
            generated_at=current_time.timetz().replace(tzinfo=None),
        )
        artifacts = renderer(snapshot, storage, output_dir, settings.assets)
        job.artifact_manifest = _artifact_manifest(artifacts)
        job.status = "completed"
        job.completed_at = datetime.now(UTC)
        db.commit()
    except Exception:
        if output_dir is not None and output_dir.exists():
            storage.delete_generation_files(output_dir.iterdir())
            output_dir.rmdir()
        job.status = "failed" if job.attempts >= 3 else "queued"
        job.started_at = None
        job.completed_at = datetime.now(UTC) if job.status == "failed" else None
        job.error_code = "render_failed"
        job.error_summary = "报告生成失败，已隐藏内部错误详情"
        db.commit()
    return job.id


class GenerationWorker:
    def __init__(
        self,
        session_factory: SessionFactory,
        settings: GenerationJobSettings,
        *,
        renderer: Renderer = render_report_set,
    ) -> None:
        self._session_factory = session_factory
        self._settings = settings
        self._renderer = renderer
        self._lock = asyncio.Lock()
        self._stop = asyncio.Event()

    def _run_once_sync(self) -> UUID | None:
        with self._session_factory() as db:
            return process_next_generation(db, self._settings, renderer=self._renderer)

    async def run_once(self) -> UUID | None:
        async with self._lock:
            return await asyncio.to_thread(self._run_once_sync)

    async def run(self, *, poll_seconds: float) -> None:
        while not self._stop.is_set():
            processed = await self.run_once()
            if processed is not None:
                continue
            with suppress(TimeoutError):
                await asyncio.wait_for(self._stop.wait(), timeout=poll_seconds)

    def stop(self) -> None:
        self._stop.set()
