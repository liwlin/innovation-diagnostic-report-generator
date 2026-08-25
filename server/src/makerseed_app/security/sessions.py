from __future__ import annotations

import hashlib
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import Depends, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..database import get_db
from ..errors import ApiError
from ..models import Session as UserSession
from ..models import User
from .rate_limit import as_utc


@dataclass(frozen=True)
class SessionTokens:
    session_token: str
    csrf_token: str
    expires_at: datetime


def hash_session_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_session(
    db: Session,
    user: User,
    *,
    ttl_minutes: int,
    now: datetime | None = None,
) -> SessionTokens:
    created_at = now or datetime.now(UTC)
    session_token = secrets.token_urlsafe(32)
    csrf_token = secrets.token_urlsafe(32)
    expires_at = created_at + timedelta(minutes=ttl_minutes)
    db.add(
        UserSession(
            user_id=user.id,
            token_hash=hash_session_token(session_token),
            created_at=created_at,
            last_seen_at=created_at,
            expires_at=expires_at,
        )
    )
    return SessionTokens(session_token, csrf_token, expires_at)


def _authentication_required() -> ApiError:
    return ApiError("authentication_required", "请先登录", 401)


def resolve_user_and_session(request: Request, db: Session) -> tuple[User, UserSession]:
    settings = request.app.state.settings
    raw_token = request.cookies.get(settings.session_cookie_name)
    if not raw_token:
        raise _authentication_required()
    statement = (
        select(User, UserSession)
        .join(UserSession, UserSession.user_id == User.id)
        .where(UserSession.token_hash == hash_session_token(raw_token))
    )
    row = db.execute(statement).one_or_none()
    if row is None:
        raise _authentication_required()
    user, user_session = row
    now = datetime.now(UTC)
    if (
        not user.is_active
        or user_session.invalidated_at is not None
        or as_utc(user_session.expires_at) <= now
    ):
        raise _authentication_required()
    return user, user_session


def require_user(request: Request, db: Annotated[Session, Depends(get_db)]) -> User:
    user, _user_session = resolve_user_and_session(request, db)
    return user


def require_admin(user: Annotated[User, Depends(require_user)]) -> User:
    if user.role != "admin":
        raise ApiError("admin_required", "需要管理员权限", 403)
    return user
