from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from .base import JSON_DOCUMENT, Base, JsonObject, UuidPrimaryKeyMixin, utc_now


class EmergencyImport(UuidPrimaryKeyMixin, Base):
    __tablename__ = "emergency_imports"
    __table_args__ = (
        CheckConstraint(
            "status IN ('previewed','completed','failed')", name="ck_emergency_imports_status"
        ),
    )

    sha256: Mapped[str] = mapped_column(String(64), nullable=False, unique=True, index=True)
    actor_user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    summary: Mapped[JsonObject] = mapped_column(JSON_DOCUMENT, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
