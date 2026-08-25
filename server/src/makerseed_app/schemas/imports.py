from __future__ import annotations

import re
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

HOSTNAME = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
)


class AiUseEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")

    evaluation_id: UUID
    provider_host: str = Field(min_length=1, max_length=253)
    model: str = Field(min_length=1, max_length=120)
    field_key: str = Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9_-]+$")
    duration_ms: int = Field(ge=0, le=600_000)
    success: bool

    @field_validator("provider_host")
    @classmethod
    def validate_hostname_only(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not HOSTNAME.fullmatch(normalized):
            raise ValueError("provider_host must be a hostname without URL components")
        return normalized
