from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..database import get_db
from ..errors import ApiError
from ..models import Evaluation, User
from ..schemas.imports import AiUseEvent
from ..security.csrf import require_csrf
from ..security.sessions import require_user
from ..services.audit import write_audit_event

router = APIRouter(prefix="/api/events")


@router.post("/ai-use", status_code=204)
def record_ai_use(
    event: AiUseEvent,
    _csrf: Annotated[None, Depends(require_csrf)],
    actor: Annotated[User, Depends(require_user)],
    db: Annotated[Session, Depends(get_db)],
) -> None:
    if db.get(Evaluation, event.evaluation_id) is None:
        raise ApiError("evaluation_not_found", "未找到该记录", 404)
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="ai_polish_used",
        target_type="evaluation",
        target_id=event.evaluation_id,
        target_label="",
        metadata={
            "provider_host": event.provider_host,
            "model": event.model,
            "field_key": event.field_key,
            "duration_ms": event.duration_ms,
            "outcome": "success" if event.success else "failure",
        },
    )
    db.commit()
