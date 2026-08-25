from __future__ import annotations

from pathlib import Path
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..database import get_db
from ..errors import ApiError
from ..models import GenerationRecord, User
from ..reports.jobs import enqueue_generation, job_settings_from_app
from ..reports.storage import ReportStorage, UnsafeReportPath
from ..schemas.generations import GenerationResponse
from ..security.csrf import require_csrf
from ..security.sessions import require_user
from ..services.audit import write_audit_event

router = APIRouter(prefix="/api")


def _response(job: GenerationRecord) -> dict[str, object]:
    return {
        "id": job.id,
        "evaluation_id": job.evaluation_id,
        "created_by_id": job.created_by_id,
        "status": job.status,
        "attempts": job.attempts,
        "renderer_version": job.renderer_version,
        "created_at": job.created_at,
        "started_at": job.started_at,
        "completed_at": job.completed_at,
        "artifacts": job.artifact_manifest.get("artifacts", []),
        "error_code": job.error_code,
        "error_summary": job.error_summary,
    }


def _get_job(db: Session, generation_id: UUID) -> GenerationRecord:
    job = db.get(GenerationRecord, generation_id)
    if job is None:
        raise ApiError("generation_not_found", "未找到该生成记录", 404)
    return job


@router.post(
    "/evaluations/{evaluation_id}/generations",
    response_model=GenerationResponse,
    status_code=202,
)
def create_generation(
    evaluation_id: UUID,
    request: Request,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    job = enqueue_generation(
        db,
        evaluation_id=evaluation_id,
        actor_id=actor.id,
        settings=job_settings_from_app(request.app.state.settings),
    )
    return _response(job)


@router.get(
    "/evaluations/{evaluation_id}/generations",
    response_model=list[GenerationResponse],
)
def list_generations(
    evaluation_id: UUID,
    _actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> list[dict[str, object]]:
    jobs = db.scalars(
        select(GenerationRecord)
        .where(GenerationRecord.evaluation_id == evaluation_id)
        .order_by(GenerationRecord.created_at.desc(), GenerationRecord.id.desc())
    ).all()
    return [_response(job) for job in jobs]


@router.get("/generations/{generation_id}", response_model=GenerationResponse)
def get_generation(
    generation_id: UUID,
    _actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    return _response(_get_job(db, generation_id))


@router.post("/generations/{generation_id}/retry", response_model=GenerationResponse)
def retry_generation(
    generation_id: UUID,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    job = _get_job(db, generation_id)
    if job.status != "failed":
        raise ApiError("generation_not_failed", "只有失败任务可以重试", 409)
    job.status = "queued"
    job.attempts = 0
    job.started_at = None
    job.completed_at = None
    job.error_code = None
    job.error_summary = None
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="generation_retried",
        target_type="generation",
        target_id=job.id,
        metadata={"evaluation_id": str(job.evaluation_id)},
    )
    db.commit()
    db.refresh(job)
    return _response(job)


@router.get("/generations/{generation_id}/files/{artifact_id}")
def download_generation_artifact(
    generation_id: UUID,
    artifact_id: str,
    request: Request,
    _actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> FileResponse:
    job = _get_job(db, generation_id)
    artifact = next(
        (
            item
            for item in job.artifact_manifest.get("artifacts", [])
            if item.get("id") == artifact_id
        ),
        None,
    )
    if artifact is None:
        raise ApiError("artifact_not_found", "未找到该报告文件", 404)
    storage = ReportStorage(request.app.state.settings.report_root)
    try:
        path = storage.resolve_existing_file(str(artifact["relative_path"]))
    except UnsafeReportPath as error:
        raise ApiError("artifact_not_found", "未找到该报告文件", 404) from error
    return FileResponse(
        path=path,
        media_type=str(artifact["mime"]),
        filename=Path(path).name,
        content_disposition_type="attachment",
        headers={
            "Cache-Control": "no-store, private",
            "X-Content-Type-Options": "nosniff",
        },
    )
