from __future__ import annotations

from datetime import date, datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator

ShortText = Annotated[str, StringConstraints(max_length=200)]
LongText = Annotated[str, StringConstraints(max_length=5000)]


class SkillPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    m: ShortText = ""
    p: Annotated[str, StringConstraints(max_length=1000)] = ""
    r: int = Field(default=0, ge=0, le=5)


class DirectionCustomPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: ShortText = ""
    desc: Annotated[str, StringConstraints(max_length=500)] = ""


class EvaluationPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="forbid")

    schema_version: Literal[1] = 1
    mods: list[ShortText] = Field(default_factory=list, max_length=50)
    custom_mods: list[ShortText] = Field(default_factory=list, alias="customMods", max_length=50)
    chart: Literal["radar", "bar", "dot"] = "radar"
    rates: list[int] = Field(default_factory=lambda: [0, 0, 0, 0, 0], min_length=5, max_length=5)
    skills: list[SkillPayload] = Field(
        default_factory=lambda: [SkillPayload(), SkillPayload(), SkillPayload()],
        min_length=3,
        max_length=3,
    )
    obs1: LongText = ""
    obs2: LongText = ""
    direction: int = Field(default=-1, alias="dir", ge=-1, le=4)
    reason: LongText = ""
    class_index: ShortText = Field(default="", alias="classIndex")
    recommended_class: ShortText = ""
    direction_custom: DirectionCustomPayload = Field(
        default_factory=DirectionCustomPayload, alias="dirCustom"
    )
    attendp: ShortText = "是"
    talk: ShortText = "已完成"
    intent: ShortText = "高"
    why: LongText = ""
    ref: LongText = ""
    follow: LongText = ""
    note: LongText = ""
    generated: bool = False

    @field_validator("rates")
    @classmethod
    def validate_rate_values(cls, values: list[int]) -> list[int]:
        if any(value < 0 or value > 5 for value in values):
            raise ValueError("rates must be between 0 and 5")
        return values


class StudentInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: UUID | None = None
    name: Annotated[str, StringConstraints(min_length=1, max_length=160)]
    grade: Annotated[str, StringConstraints(max_length=80)] = ""
    slot: Annotated[str, StringConstraints(max_length=160)] = ""

    @field_validator("name")
    @classmethod
    def normalize_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("name is required")
        return normalized


class BatchCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    display_name: Annotated[str, StringConstraints(min_length=1, max_length=160)]
    event_date: date
    date_label: Annotated[str, StringConstraints(min_length=1, max_length=80)]
    teacher_label: Annotated[str, StringConstraints(max_length=120)] = ""
    fill_date: date


class BatchResponse(BatchCreate):
    id: UUID
    version: int


class EvaluationCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    student: StudentInput
    payload: EvaluationPayload


class EvaluationUpdate(EvaluationCreate):
    version: int = Field(ge=1)


class UserSummary(BaseModel):
    id: UUID
    display_name: str


class EditorResponse(BaseModel):
    evaluation_id: UUID
    version: int
    batch: dict[str, object]
    student: dict[str, object]
    payload: dict[str, object]
    updated_at: datetime
    updated_by: UserSummary


class EvaluationSummary(BaseModel):
    evaluation_id: UUID
    version: int
    student_name: str
    grade: str
    batch_id: UUID
    batch_name: str
    event_date: date
    recommended_class: str
    created_by: UserSummary
    updated_by: UserSummary
    updated_at: datetime
    trashed: bool
    generation_status: str | None = None


class EvaluationPage(BaseModel):
    items: list[EvaluationSummary]
    next_cursor: str | None
