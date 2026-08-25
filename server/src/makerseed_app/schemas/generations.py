from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel


class ArtifactResponse(BaseModel):
    id: str
    variant: Literal["with", "without"]
    format: Literal["pdf", "png"]
    relative_path: str
    sha256: str
    size: int
    mime: Literal["application/pdf", "image/png"]


class GenerationResponse(BaseModel):
    id: UUID
    evaluation_id: UUID
    created_by_id: UUID
    status: Literal["queued", "running", "completed", "failed"]
    attempts: int
    renderer_version: str
    created_at: datetime
    started_at: datetime | None
    completed_at: datetime | None
    artifacts: list[ArtifactResponse]
    error_code: str | None
    error_summary: str | None
