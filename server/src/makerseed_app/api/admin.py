from __future__ import annotations

from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import User
from ..schemas.admin import AdminUserResponse, AuditPage, UserCreate, UserUpdate
from ..security.csrf import require_csrf
from ..security.sessions import require_admin
from ..services import users as user_service

router = APIRouter(prefix="/api/admin")


@router.get("/users", response_model=list[AdminUserResponse])
def list_users(
    _admin: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
) -> list[User]:
    return user_service.list_users(db)


@router.post("/users", response_model=AdminUserResponse, status_code=201)
def create_user(
    request: UserCreate,
    _csrf: Annotated[None, Depends(require_csrf)],
    admin: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
) -> User:
    return user_service.create_user(db, request, admin)


@router.patch("/users/{user_id}", response_model=AdminUserResponse)
def update_user(
    user_id: UUID,
    request: UserUpdate,
    _csrf: Annotated[None, Depends(require_csrf)],
    admin: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
) -> User:
    return user_service.update_user(db, user_id, request, admin)


@router.get("/audit", response_model=AuditPage)
def list_audit(
    _admin: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
    actor_user_id: UUID | None = None,
    action: str | None = Query(default=None, max_length=80),
    target_id: UUID | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    cursor: str | None = Query(default=None, max_length=500),
    limit: int = Query(default=100, ge=1, le=100),
) -> dict[str, object]:
    return user_service.list_audit_events(
        db,
        actor_user_id=actor_user_id,
        action=action,
        target_id=target_id,
        date_from=date_from,
        date_to=date_to,
        cursor=cursor,
        limit=limit,
    )
