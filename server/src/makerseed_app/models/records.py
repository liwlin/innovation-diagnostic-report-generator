from __future__ import annotations

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import CheckConstraint, Date, DateTime, ForeignKey, Integer, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from .base import (
    JSON_DOCUMENT,
    Base,
    JsonObject,
    TimestampMixin,
    UuidPrimaryKeyMixin,
    utc_now,
)


class Batch(UuidPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "batches"
    __table_args__ = (CheckConstraint("version >= 1", name="ck_batches_version_positive"),)

    display_name: Mapped[str] = mapped_column(String(160), nullable=False, index=True)
    event_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    date_label: Mapped[str] = mapped_column(String(80), nullable=False)
    teacher_label: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    fill_date: Mapped[date] = mapped_column(Date, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_by_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )


class Student(UuidPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "students"

    batch_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("batches.id", ondelete="CASCADE"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(160), nullable=False, index=True)
    grade: Mapped[str] = mapped_column(String(80), nullable=False, default="", index=True)
    slot: Mapped[str] = mapped_column(String(160), nullable=False, default="")


class Evaluation(UuidPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "evaluations"
    __table_args__ = (
        CheckConstraint("version >= 1", name="ck_evaluations_version_positive"),
        CheckConstraint("schema_version >= 1", name="ck_evaluations_schema_version_positive"),
    )

    student_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("students.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
        index=True,
    )
    payload: Mapped[JsonObject] = mapped_column(JSON_DOCUMENT, nullable=False, default=dict)
    schema_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    recommended_class: Mapped[str] = mapped_column(
        String(200), nullable=False, default="", index=True
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_by_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    updated_by_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, index=True
    )
    deleted_by_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    __mapper_args__ = {"version_id_col": version}


class EvaluationVersion(UuidPrimaryKeyMixin, Base):
    __tablename__ = "evaluation_versions"

    evaluation_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("evaluations.id", ondelete="CASCADE"), nullable=False, index=True
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    snapshot: Mapped[JsonObject] = mapped_column(JSON_DOCUMENT, nullable=False)
    edited_by_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now
    )
