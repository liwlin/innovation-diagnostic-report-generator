from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..database import get_db
from ..errors import ApiError
from ..models import Session as UserSession
from ..models import User
from ..schemas.auth import LoginRequest, SessionResponse, UserResponse
from ..security.csrf import require_csrf
from ..security.passwords import hash_password, verify_password
from ..security.rate_limit import (
    clear_login_failures,
    is_locked,
    record_login_failure,
)
from ..security.sessions import (
    create_session,
    hash_session_token,
    require_user,
)
from ..services.audit import write_audit_event

router = APIRouter(prefix="/api")
_DUMMY_PASSWORD_HASH = hash_password("dummy password used only for timing normalization")


def _user_response(user: User) -> dict[str, object]:
    return SessionResponse(user=UserResponse.model_validate(user)).model_dump(mode="json")


def _set_auth_cookies(
    response: Response, request: Request, session_token: str, csrf_token: str
) -> None:
    settings = request.app.state.settings
    max_age = settings.session_ttl_minutes * 60
    response.set_cookie(
        settings.session_cookie_name,
        session_token,
        max_age=max_age,
        httponly=True,
        secure=settings.secure_cookies,
        samesite="lax",
        path="/",
    )
    response.set_cookie(
        settings.csrf_cookie_name,
        csrf_token,
        max_age=max_age,
        httponly=False,
        secure=settings.secure_cookies,
        samesite="lax",
        path="/",
    )


@router.post("/auth/login")
def login(
    request: Request,
    payload: LoginRequest,
    db: Annotated[Session, Depends(get_db)],
) -> Response:
    settings = request.app.state.settings
    now = datetime.now(UTC)
    user = db.scalar(select(User).where(User.username == payload.username))
    if user is None:
        verify_password(payload.password, _DUMMY_PASSWORD_HASH)
        write_audit_event(
            db,
            actor_user_id=None,
            action="login_failed",
            target_type="user",
            target_label=payload.username,
            metadata={"username": payload.username, "outcome": "unknown_user"},
        )
        db.commit()
        raise ApiError("invalid_credentials", "账号或密码错误", 401)
    if not user.is_active:
        write_audit_event(
            db,
            actor_user_id=user.id,
            action="login_blocked",
            target_type="user",
            target_id=user.id,
            metadata={"outcome": "disabled"},
        )
        db.commit()
        raise ApiError("account_disabled", "账号已停用", 403)
    if is_locked(user, now):
        write_audit_event(
            db,
            actor_user_id=user.id,
            action="login_blocked",
            target_type="user",
            target_id=user.id,
            metadata={"outcome": "locked"},
        )
        db.commit()
        raise ApiError("account_locked", "登录失败次数过多，请稍后再试", 429)
    if not verify_password(payload.password, user.password_hash):
        locked = record_login_failure(
            user,
            now=now,
            max_failures=settings.max_failed_logins,
            lockout_minutes=settings.lockout_minutes,
        )
        write_audit_event(
            db,
            actor_user_id=user.id,
            action="login_failed",
            target_type="user",
            target_id=user.id,
            metadata={"username": user.username, "outcome": "locked" if locked else "invalid"},
        )
        db.commit()
        if locked:
            raise ApiError("account_locked", "登录失败次数过多，请稍后再试", 429)
        raise ApiError("invalid_credentials", "账号或密码错误", 401)

    clear_login_failures(user)
    user.last_login_at = now
    tokens = create_session(db, user, ttl_minutes=settings.session_ttl_minutes, now=now)
    write_audit_event(
        db,
        actor_user_id=user.id,
        action="login_succeeded",
        target_type="user",
        target_id=user.id,
        metadata={"outcome": "success"},
    )
    db.commit()
    response = JSONResponse(_user_response(user))
    _set_auth_cookies(response, request, tokens.session_token, tokens.csrf_token)
    return response


@router.get("/session")
def get_session(user: Annotated[User, Depends(require_user)]) -> dict[str, object]:
    return _user_response(user)


@router.post("/auth/logout", status_code=204)
def logout(
    request: Request,
    response: Response,
    _csrf: Annotated[None, Depends(require_csrf)],
    _user: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> None:
    settings = request.app.state.settings
    raw_token = request.cookies.get(settings.session_cookie_name, "")
    if raw_token:
        session = db.scalar(
            select(UserSession).where(UserSession.token_hash == hash_session_token(raw_token))
        )
        if session is not None:
            session.invalidated_at = datetime.now(UTC)
            db.commit()
    response.delete_cookie(settings.session_cookie_name, path="/")
    response.delete_cookie(settings.csrf_cookie_name, path="/")
