from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import (
    BaseModel,
    ConfigDict,
    StringConstraints,
    field_validator,
    model_validator,
)


class UserCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: Annotated[str, StringConstraints(min_length=1, max_length=80)]
    display_name: Annotated[str, StringConstraints(min_length=1, max_length=120)]
    role: Literal["teacher", "admin"] = "teacher"
    password: Annotated[str, StringConstraints(min_length=12, max_length=1024)]

    @field_validator("username")
    @classmethod
    def normalize_username(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not normalized:
            raise ValueError("username is required")
        return normalized


class UserUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    display_name: Annotated[str, StringConstraints(min_length=1, max_length=120)] | None = None
    role: Literal["teacher", "admin"] | None = None
    is_active: bool | None = None
    password: Annotated[str, StringConstraints(min_length=12, max_length=1024)] | None = None

    @model_validator(mode="after")
    def require_change(self) -> UserUpdate:
        if all(
            value is None for value in (self.display_name, self.role, self.is_active, self.password)
        ):
            raise ValueError("at least one change is required")
        return self


class AdminUserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    username: str
    display_name: str
    role: Literal["teacher", "admin"]
    is_active: bool
    created_at: datetime
    updated_at: datetime
    last_login_at: datetime | None


class AuditEventResponse(BaseModel):
    id: UUID
    actor_user_id: UUID | None
    action: str
    target_type: str
    target_id: UUID | None
    target_label: str
    event_metadata: dict[str, object]
    created_at: datetime


class AuditPage(BaseModel):
    items: list[AuditEventResponse]
    next_cursor: str | None
