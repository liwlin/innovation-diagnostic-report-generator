from __future__ import annotations

from datetime import date
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import User
from ..reports.storage import ReportStorage
from ..schemas.records import (
    BatchCreate,
    BatchResponse,
    EditorResponse,
    EvaluationCreate,
    EvaluationPage,
    EvaluationUpdate,
    PermanentDeleteRequest,
)
from ..security.csrf import require_csrf
from ..security.sessions import require_admin, require_user
from ..services import records as record_service

router = APIRouter(prefix="/api")


@router.post("/batches", response_model=BatchResponse, status_code=201)
def create_batch(
    request: BatchCreate,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> BatchResponse:
    batch = record_service.create_batch(db, request, actor)
    return BatchResponse.model_validate(batch, from_attributes=True)


@router.post("/batches/{batch_id}/evaluations", response_model=EditorResponse, status_code=201)
def create_evaluation(
    batch_id: UUID,
    request: EvaluationCreate,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    evaluation = record_service.create_evaluation(
        db, batch_id=batch_id, request=request, actor=actor
    )
    return record_service.get_editor_document(db, evaluation.id)


@router.get("/evaluations", response_model=EvaluationPage)
def list_evaluations(
    _actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
    q: str | None = Query(default=None, max_length=160),
    grade: str | None = Query(default=None, max_length=80),
    batch_id: UUID | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    recommended_class: str | None = Query(default=None, max_length=200),
    created_by: UUID | None = None,
    generation_status: Literal["none", "queued", "running", "completed", "failed"] | None = None,
    trashed: bool = False,
    cursor: str | None = Query(default=None, max_length=500),
    limit: int = Query(default=50, ge=1, le=100),
) -> dict[str, object]:
    return record_service.list_evaluations(
        db,
        q=q,
        grade=grade,
        batch_id=batch_id,
        date_from=date_from,
        date_to=date_to,
        recommended_class=recommended_class,
        created_by=created_by,
        generation_status=generation_status,
        trashed=trashed,
        cursor=cursor,
        limit=limit,
    )


@router.get("/evaluations/{evaluation_id}/editor", response_model=EditorResponse)
def get_editor(
    evaluation_id: UUID,
    _actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    return record_service.get_editor_document(db, evaluation_id)


@router.put("/evaluations/{evaluation_id}", response_model=EditorResponse)
def update_evaluation(
    evaluation_id: UUID,
    request: EvaluationUpdate,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    return record_service.update_evaluation(
        db,
        evaluation_id=evaluation_id,
        expected_version=request.version,
        request=request,
        actor=actor,
    )


@router.post("/evaluations/{evaluation_id}/trash", response_model=EditorResponse)
def trash_evaluation(
    evaluation_id: UUID,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    return record_service.trash_evaluation(db, evaluation_id=evaluation_id, actor=actor)


@router.post("/evaluations/{evaluation_id}/restore", response_model=EditorResponse)
def restore_evaluation(
    evaluation_id: UUID,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    return record_service.restore_evaluation(db, evaluation_id=evaluation_id, actor=actor)


@router.delete("/evaluations/{evaluation_id}", status_code=204)
def permanently_delete_evaluation(
    evaluation_id: UUID,
    request: PermanentDeleteRequest,
    http_request: Request,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
) -> None:
    record_service.permanently_delete_evaluation(
        db,
        evaluation_id=evaluation_id,
        reason=request.reason,
        actor=actor,
        storage=ReportStorage(http_request.app.state.settings.report_root),
    )
