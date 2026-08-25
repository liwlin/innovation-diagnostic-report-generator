from __future__ import annotations

import base64
import json
from datetime import UTC, date, datetime
from uuid import UUID

from sqlalchemy import func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..errors import ApiError
from ..models import AuditEvent, User
from ..models import Session as UserSession
from ..schemas.admin import UserCreate, UserUpdate
from ..security.passwords import hash_password
from .audit import write_audit_event


def list_users(db: Session) -> list[User]:
    return list(db.scalars(select(User).order_by(User.username.asc())).all())


def create_user(db: Session, request: UserCreate, actor: User) -> User:
    user = User(
        username=request.username,
        display_name=request.display_name.strip(),
        role=request.role,
        password_hash=hash_password(request.password),
    )
    db.add(user)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise ApiError("username_exists", "该账号已存在", 409) from None
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="user_created",
        target_type="user",
        target_id=user.id,
        target_label=user.username,
        metadata={"role": user.role},
    )
    db.commit()
    db.refresh(user)
    return user


def _active_admin_count(db: Session) -> int:
    return int(
        db.scalar(
            select(func.count()).select_from(User).where(User.role == "admin", User.is_active)
        )
        or 0
    )


def update_user(db: Session, user_id: UUID, request: UserUpdate, actor: User) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise ApiError("user_not_found", "未找到该账号", 404)
    removes_active_admin = (
        user.role == "admin"
        and user.is_active
        and (request.role == "teacher" or request.is_active is False)
    )
    if removes_active_admin and _active_admin_count(db) <= 1:
        raise ApiError("last_admin_required", "必须保留至少一个启用的管理员", 409)

    changes: list[str] = []
    if request.display_name is not None:
        user.display_name = request.display_name.strip()
        changes.append("display_name")
    if request.role is not None and request.role != user.role:
        user.role = request.role
        changes.append("role")
    if request.is_active is not None and request.is_active != user.is_active:
        user.is_active = request.is_active
        changes.append("is_active")
    if request.password is not None:
        user.password_hash = hash_password(request.password)
        changes.append("credential_reset")

    should_revoke = request.password is not None or request.is_active is False
    if should_revoke:
        db.execute(
            update(UserSession)
            .where(UserSession.user_id == user.id, UserSession.invalidated_at.is_(None))
            .values(invalidated_at=datetime.now(UTC))
        )
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="user_updated",
        target_type="user",
        target_id=user.id,
        target_label=user.username,
        metadata={"changes": changes},
    )
    db.commit()
    db.refresh(user)
    return user


def _encode_audit_cursor(event: AuditEvent) -> str:
    value = json.dumps([event.created_at.isoformat(), str(event.id)], separators=(",", ":"))
    return base64.urlsafe_b64encode(value.encode()).decode().rstrip("=")


def _decode_audit_cursor(value: str) -> tuple[datetime, UUID]:
    try:
        padded = value + "=" * (-len(value) % 4)
        timestamp, identifier = json.loads(base64.urlsafe_b64decode(padded).decode())
        parsed = datetime.fromisoformat(timestamp)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed, UUID(identifier)
    except (ValueError, TypeError, json.JSONDecodeError) as error:
        raise ApiError("invalid_cursor", "分页游标无效", 400) from error


def list_audit_events(
    db: Session,
    *,
    actor_user_id: UUID | None,
    action: str | None,
    target_id: UUID | None,
    date_from: date | None,
    date_to: date | None,
    cursor: str | None,
    limit: int,
) -> dict[str, object]:
    statement = select(AuditEvent)
    if actor_user_id:
        statement = statement.where(AuditEvent.actor_user_id == actor_user_id)
    if action:
        statement = statement.where(AuditEvent.action == action)
    if target_id:
        statement = statement.where(AuditEvent.target_id == target_id)
    if date_from:
        statement = statement.where(
            AuditEvent.created_at >= datetime.combine(date_from, datetime.min.time(), UTC)
        )
    if date_to:
        statement = statement.where(
            AuditEvent.created_at < datetime.combine(date_to, datetime.max.time(), UTC)
        )
    if cursor:
        cursor_time, cursor_id = _decode_audit_cursor(cursor)
        statement = statement.where(
            or_(
                AuditEvent.created_at < cursor_time,
                (AuditEvent.created_at == cursor_time) & (AuditEvent.id < cursor_id),
            )
        )
    rows = list(
        db.scalars(
            statement.order_by(AuditEvent.created_at.desc(), AuditEvent.id.desc()).limit(limit + 1)
        ).all()
    )
    has_more = len(rows) > limit
    items = rows[:limit]
    next_cursor = _encode_audit_cursor(items[-1]) if has_more and items else None
    return {
        "items": [
            {
                "id": event.id,
                "actor_user_id": event.actor_user_id,
                "action": event.action,
                "target_type": event.target_type,
                "target_id": event.target_id,
                "target_label": event.target_label,
                "event_metadata": event.event_metadata,
                "created_at": event.created_at,
            }
            for event in items
        ],
        "next_cursor": next_cursor,
    }
