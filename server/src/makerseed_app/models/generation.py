from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, String, Text, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from .base import JSON_DOCUMENT, Base, JsonObject, TimestampMixin, UuidPrimaryKeyMixin


class GenerationRecord(UuidPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "generation_records"
    __table_args__ = (
        CheckConstraint(
            "status IN ('queued','running','completed','failed')",
            name="ck_generation_records_status",
        ),
    )

    evaluation_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("evaluations.id", ondelete="CASCADE"), nullable=False, index=True
    )
    created_by_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="queued", index=True)
    input_snapshot: Mapped[JsonObject] = mapped_column(JSON_DOCUMENT, nullable=False)
    renderer_version: Mapped[str] = mapped_column(String(80), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    artifact_manifest: Mapped[JsonObject] = mapped_column(
        JSON_DOCUMENT, nullable=False, default=dict
    )
    error_code: Mapped[str | None] = mapped_column(String(80), nullable=True)
    error_summary: Mapped[str | None] = mapped_column(Text, nullable=True)
