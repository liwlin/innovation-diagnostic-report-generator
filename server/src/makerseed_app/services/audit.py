from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy.orm import Session

from ..models import AuditEvent

FORBIDDEN_AUDIT_KEY_PARTS = (
    "password",
    "token",
    "cookie",
    "authorization",
    "api_key",
    "apikey",
    "prompt",
    "response_text",
    "payload",
)


def _validate_metadata(value: Any, path: str = "metadata") -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            normalized = str(key).lower()
            if any(part in normalized for part in FORBIDDEN_AUDIT_KEY_PARTS):
                raise ValueError(f"forbidden audit metadata key: {path}.{key}")
            _validate_metadata(nested, f"{path}.{key}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            _validate_metadata(nested, f"{path}[{index}]")


def write_audit_event(
    db: Session,
    *,
    actor_user_id: UUID | None,
    action: str,
    target_type: str,
    target_id: UUID | None = None,
    target_label: str = "",
    metadata: dict[str, Any] | None = None,
) -> AuditEvent:
    event_metadata = metadata or {}
    _validate_metadata(event_metadata)
    event = AuditEvent(
        actor_user_id=actor_user_id,
        action=action,
        target_type=target_type,
        target_id=target_id,
        target_label=target_label[:200],
        event_metadata=event_metadata,
    )
    db.add(event)
    return event
