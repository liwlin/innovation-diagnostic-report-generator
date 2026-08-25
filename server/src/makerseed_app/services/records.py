from __future__ import annotations

import base64
import json
from datetime import UTC, date, datetime
from uuid import UUID

from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session, aliased
from sqlalchemy.orm.exc import StaleDataError

from ..errors import ApiError
from ..models import Batch, Evaluation, EvaluationVersion, GenerationRecord, Student, User
from ..schemas.records import BatchCreate, EvaluationCreate, EvaluationUpdate
from .audit import write_audit_event


def create_batch(db: Session, request: BatchCreate, actor: User) -> Batch:
    batch = Batch(
        display_name=request.display_name.strip(),
        event_date=request.event_date,
        date_label=request.date_label.strip(),
        teacher_label=request.teacher_label.strip(),
        fill_date=request.fill_date,
        created_by_id=actor.id,
    )
    db.add(batch)
    db.flush()
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="batch_created",
        target_type="batch",
        target_id=batch.id,
        target_label=batch.display_name,
    )
    db.commit()
    db.refresh(batch)
    return batch


def _get_batch(db: Session, batch_id: UUID) -> Batch:
    batch = db.get(Batch, batch_id)
    if batch is None:
        raise ApiError("batch_not_found", "未找到该批次", 404)
    return batch


def create_evaluation(
    db: Session,
    *,
    batch_id: UUID,
    request: EvaluationCreate,
    actor: User,
) -> Evaluation:
    _get_batch(db, batch_id)
    student = Student(
        batch_id=batch_id,
        name=request.student.name,
        grade=request.student.grade.strip(),
        slot=request.student.slot.strip(),
    )
    db.add(student)
    db.flush()
    payload = request.payload.model_dump(by_alias=True)
    evaluation = Evaluation(
        student_id=student.id,
        payload=payload,
        schema_version=request.payload.schema_version,
        recommended_class=request.payload.recommended_class.strip(),
        created_by_id=actor.id,
        updated_by_id=actor.id,
    )
    db.add(evaluation)
    db.flush()
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="evaluation_created",
        target_type="evaluation",
        target_id=evaluation.id,
        target_label=student.name,
        metadata={"batch_id": str(batch_id)},
    )
    db.commit()
    db.refresh(evaluation)
    return evaluation


def _editor_statement(evaluation_id: UUID):
    updated_user = aliased(User)
    return (
        select(Evaluation, Student, Batch, updated_user)
        .join(Student, Student.id == Evaluation.student_id)
        .join(Batch, Batch.id == Student.batch_id)
        .join(updated_user, updated_user.id == Evaluation.updated_by_id)
        .where(Evaluation.id == evaluation_id)
    )


def get_editor_document(db: Session, evaluation_id: UUID) -> dict[str, object]:
    row = db.execute(_editor_statement(evaluation_id)).one_or_none()
    if row is None:
        raise ApiError("evaluation_not_found", "未找到该记录", 404)
    evaluation, student, batch, updated_user = row
    return {
        "evaluation_id": evaluation.id,
        "version": evaluation.version,
        "batch": {
            "id": batch.id,
            "date": batch.date_label,
            "event_date": batch.event_date,
            "teacher": batch.teacher_label,
            "fill_date": batch.fill_date,
            "display_name": batch.display_name,
            "version": batch.version,
        },
        "student": {
            "id": student.id,
            "name": student.name,
            "grade": student.grade,
            "slot": student.slot,
        },
        "payload": evaluation.payload,
        "updated_at": evaluation.updated_at,
        "updated_by": {"id": updated_user.id, "display_name": updated_user.display_name},
    }


def _evaluation_snapshot(evaluation: Evaluation, student: Student) -> dict[str, object]:
    return {
        "version": evaluation.version,
        "student": {
            "id": str(student.id),
            "name": student.name,
            "grade": student.grade,
            "slot": student.slot,
        },
        "payload": evaluation.payload,
        "updated_by_id": str(evaluation.updated_by_id),
        "updated_at": evaluation.updated_at.isoformat(),
    }


def update_evaluation(
    db: Session,
    *,
    evaluation_id: UUID,
    expected_version: int,
    request: EvaluationUpdate,
    actor: User,
) -> dict[str, object]:
    evaluation = db.get(Evaluation, evaluation_id)
    if evaluation is None:
        raise ApiError("evaluation_not_found", "未找到该记录", 404)
    if evaluation.version != expected_version:
        raise ApiError(
            "version_conflict",
            "记录已被其他老师修改，请重新加载",
            409,
            {"current_version": evaluation.version},
        )
    student = db.get(Student, evaluation.student_id)
    if student is None:
        raise ApiError("evaluation_corrupt", "记录关联不完整，请联系管理员", 500)
    db.add(
        EvaluationVersion(
            evaluation_id=evaluation.id,
            version=evaluation.version,
            snapshot=_evaluation_snapshot(evaluation, student),
            edited_by_id=actor.id,
        )
    )
    student.name = request.student.name
    student.grade = request.student.grade.strip()
    student.slot = request.student.slot.strip()
    evaluation.payload = request.payload.model_dump(by_alias=True)
    evaluation.schema_version = request.payload.schema_version
    evaluation.recommended_class = request.payload.recommended_class.strip()
    evaluation.updated_by_id = actor.id
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="evaluation_updated",
        target_type="evaluation",
        target_id=evaluation.id,
        target_label=student.name,
        metadata={"from_version": expected_version},
    )
    try:
        db.commit()
    except StaleDataError:
        db.rollback()
        current_version = db.scalar(
            select(Evaluation.version).where(Evaluation.id == evaluation_id)
        )
        raise ApiError(
            "version_conflict",
            "记录已被其他老师修改，请重新加载",
            409,
            {"current_version": current_version},
        ) from None
    return get_editor_document(db, evaluation_id)


def _encode_cursor(updated_at: datetime, evaluation_id: UUID) -> str:
    encoded = json.dumps([updated_at.isoformat(), str(evaluation_id)], separators=(",", ":"))
    return base64.urlsafe_b64encode(encoded.encode("utf-8")).decode("ascii").rstrip("=")


def _decode_cursor(cursor: str) -> tuple[datetime, UUID]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        timestamp, identifier = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
        parsed = datetime.fromisoformat(timestamp)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed, UUID(identifier)
    except (ValueError, TypeError, json.JSONDecodeError) as error:
        raise ApiError("invalid_cursor", "分页游标无效", 400) from error


def list_evaluations(
    db: Session,
    *,
    q: str | None,
    grade: str | None,
    batch_id: UUID | None,
    date_from: date | None,
    date_to: date | None,
    recommended_class: str | None,
    created_by: UUID | None,
    generation_status: str | None,
    trashed: bool,
    cursor: str | None,
    limit: int,
) -> dict[str, object]:
    creator = aliased(User)
    updater = aliased(User)
    latest_generation_status = (
        select(GenerationRecord.status)
        .where(GenerationRecord.evaluation_id == Evaluation.id)
        .order_by(GenerationRecord.created_at.desc(), GenerationRecord.id.desc())
        .limit(1)
        .correlate(Evaluation)
        .scalar_subquery()
    )
    statement = (
        select(Evaluation, Student, Batch, creator, updater, latest_generation_status)
        .join(Student, Student.id == Evaluation.student_id)
        .join(Batch, Batch.id == Student.batch_id)
        .join(creator, creator.id == Evaluation.created_by_id)
        .join(updater, updater.id == Evaluation.updated_by_id)
        .where(Evaluation.deleted_at.is_not(None) if trashed else Evaluation.deleted_at.is_(None))
    )
    if q and q.strip():
        statement = statement.where(Student.name.contains(q.strip()))
    if grade:
        statement = statement.where(Student.grade == grade)
    if batch_id:
        statement = statement.where(Batch.id == batch_id)
    if date_from:
        statement = statement.where(Batch.event_date >= date_from)
    if date_to:
        statement = statement.where(Batch.event_date <= date_to)
    if recommended_class:
        statement = statement.where(Evaluation.recommended_class == recommended_class)
    if created_by:
        statement = statement.where(Evaluation.created_by_id == created_by)
    if generation_status == "none":
        statement = statement.where(latest_generation_status.is_(None))
    elif generation_status:
        statement = statement.where(latest_generation_status == generation_status)
    if cursor:
        cursor_time, cursor_id = _decode_cursor(cursor)
        statement = statement.where(
            or_(
                Evaluation.updated_at < cursor_time,
                and_(Evaluation.updated_at == cursor_time, Evaluation.id < cursor_id),
            )
        )
    rows = db.execute(
        statement.order_by(Evaluation.updated_at.desc(), Evaluation.id.desc()).limit(limit + 1)
    ).all()
    has_more = len(rows) > limit
    selected_rows = rows[:limit]
    items = [
        {
            "evaluation_id": evaluation.id,
            "version": evaluation.version,
            "student_name": student.name,
            "grade": student.grade,
            "batch_id": batch.id,
            "batch_name": batch.display_name,
            "event_date": batch.event_date,
            "recommended_class": evaluation.recommended_class,
            "created_by": {"id": creator_user.id, "display_name": creator_user.display_name},
            "updated_by": {"id": updater_user.id, "display_name": updater_user.display_name},
            "updated_at": evaluation.updated_at,
            "trashed": evaluation.deleted_at is not None,
            "generation_status": latest_status,
        }
        for evaluation, student, batch, creator_user, updater_user, latest_status in selected_rows
    ]
    next_cursor = None
    if has_more and selected_rows:
        last_evaluation = selected_rows[-1][0]
        next_cursor = _encode_cursor(last_evaluation.updated_at, last_evaluation.id)
    return {"items": items, "next_cursor": next_cursor}
