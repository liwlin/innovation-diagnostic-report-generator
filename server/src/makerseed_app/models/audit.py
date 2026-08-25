from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from .base import JSON_DOCUMENT, Base, JsonObject, UuidPrimaryKeyMixin, utc_now


class AuditEvent(UuidPrimaryKeyMixin, Base):
    __tablename__ = "audit_events"

    actor_user_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )
    action: Mapped[str] = mapped_column(String(80), nullable=False, index=True)
    target_type: Mapped[str] = mapped_column(String(80), nullable=False, index=True)
    target_id: Mapped[UUID | None] = mapped_column(Uuid, nullable=True, index=True)
    target_label: Mapped[str] = mapped_column(String(200), nullable=False, default="")
    event_metadata: Mapped[JsonObject] = mapped_column(JSON_DOCUMENT, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, index=True
    )
