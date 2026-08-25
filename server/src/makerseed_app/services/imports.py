from __future__ import annotations

import hashlib
import json
from contextlib import suppress
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import Any

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..errors import ApiError
from ..models import Batch, EmergencyImport, Evaluation, Student, User
from ..schemas.records import EvaluationPayload, StudentInput
from .audit import write_audit_event

APPROVED_TOP_LEVEL_KEYS = {
    "schema_version",
    "exported_at",
    "source_version",
    "batches",
    "class_list",
    "promo_text",
}


@dataclass(frozen=True)
class ImportRow:
    batch_display_name: str
    event_date: date
    date_label: str
    teacher_label: str
    fill_date: date
    student: dict[str, str]
    payload: dict[str, Any]

    @property
    def label(self) -> str:
        return f"{self.date_label} · {self.student['name']}"


def _invalid_import(message: str) -> ApiError:
    return ApiError("invalid_import", message, 422)


def parse_export(content: bytes) -> tuple[dict[str, Any], list[ImportRow], int]:
    try:
        document = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise _invalid_import("应急文件不是有效的 UTF-8 JSON") from error
    if not isinstance(document, dict) or set(document) - APPROVED_TOP_LEVEL_KEYS:
        raise _invalid_import("应急文件包含未允许的字段")
    if document.get("schema_version") != 1 or not isinstance(document.get("batches"), list):
        raise _invalid_import("应急文件版本或批次结构无效")
    raw_class_list = document.get("class_list")
    class_list: list[Any] = raw_class_list if isinstance(raw_class_list, list) else []
    rows: list[ImportRow] = []
    invalid = 0
    exported_date = date.today()
    with suppress(ValueError):
        exported_date = datetime.fromisoformat(
            str(document.get("exported_at", "")).replace("Z", "+00:00")
        ).date()
    for batch_value in document["batches"]:
        if not isinstance(batch_value, dict) or not isinstance(batch_value.get("students"), list):
            invalid += 1
            continue
        try:
            fill_date = date.fromisoformat(
                str(batch_value.get("fillDate") or exported_date.isoformat())
            )
        except ValueError:
            invalid += len(batch_value.get("students", [])) or 1
            continue
        date_label = str(batch_value.get("date") or fill_date.isoformat())[:80]
        teacher = str(batch_value.get("teacher") or "")[:120]
        batch_display_name = f"{date_label}_{teacher or '应急导入'}"[:160]
        for student_value in batch_value["students"]:
            if not isinstance(student_value, dict):
                invalid += 1
                continue
            class_index = str(student_value.get("classIndex") or "")
            recommended_class = ""
            if class_index.isdigit() and int(class_index) < len(class_list):
                class_value = class_list[int(class_index)]
                if isinstance(class_value, dict):
                    recommended_class = str(class_value.get("name") or "")[:200]
            payload_source = {
                "schema_version": 1,
                "mods": student_value.get("mods", []),
                "customMods": student_value.get("customMods", []),
                "chart": student_value.get("chart", "radar"),
                "rates": student_value.get("rates", [0, 0, 0, 0, 0]),
                "skills": student_value.get("skills", []),
                "obs1": student_value.get("obs1", ""),
                "obs2": student_value.get("obs2", ""),
                "dir": student_value.get("dir", -1),
                "reason": student_value.get("reason", ""),
                "classIndex": class_index,
                "recommended_class": recommended_class,
                "dirCustom": student_value.get("dirCustom", {"name": "", "desc": ""}),
                "attendp": student_value.get("attendp", ""),
                "talk": student_value.get("talk", ""),
                "intent": student_value.get("intent", ""),
                "why": student_value.get("why", ""),
                "ref": student_value.get("ref", ""),
                "follow": student_value.get("follow", ""),
                "note": student_value.get("note", ""),
                "generated": bool(student_value.get("generated", False)),
            }
            try:
                student = StudentInput.model_validate(
                    {
                        "name": student_value.get("name", ""),
                        "grade": student_value.get("grade", ""),
                        "slot": student_value.get("slot", ""),
                    }
                )
                payload = EvaluationPayload.model_validate(payload_source)
            except ValidationError:
                invalid += 1
                continue
            rows.append(
                ImportRow(
                    batch_display_name=batch_display_name,
                    event_date=fill_date,
                    date_label=date_label,
                    teacher_label=teacher,
                    fill_date=fill_date,
                    student=student.model_dump(mode="json", exclude={"id"}),
                    payload=payload.model_dump(by_alias=True),
                )
            )
    return document, rows, invalid


def _find_existing(db: Session, row: ImportRow) -> tuple[Student, Evaluation] | None:
    existing = db.execute(
        select(Student, Evaluation)
        .join(Batch, Batch.id == Student.batch_id)
        .join(Evaluation, Evaluation.student_id == Student.id)
        .where(
            Batch.event_date == row.event_date,
            Batch.display_name == row.batch_display_name,
            Student.name == row.student["name"],
        )
    ).one_or_none()
    return None if existing is None else (existing[0], existing[1])


def classify_rows(
    db: Session, rows: list[ImportRow], invalid: int
) -> tuple[dict[str, int], list[dict[str, str]]]:
    counts = {"new": 0, "duplicate": 0, "conflict": 0, "invalid": invalid}
    details: list[dict[str, str]] = []
    for row in rows:
        existing = _find_existing(db, row)
        if existing is None:
            status = "new"
        else:
            student, evaluation = existing
            same = (
                student.grade == row.student["grade"]
                and student.slot == row.student["slot"]
                and evaluation.payload == row.payload
            )
            status = "duplicate" if same else "conflict"
        counts[status] += 1
        details.append({"label": row.label, "status": status})
    return counts, details


def preview_import(db: Session, content: bytes) -> dict[str, object]:
    _document, rows, invalid = parse_export(content)
    counts, details = classify_rows(db, rows, invalid)
    return {
        "sha256": hashlib.sha256(content).hexdigest(),
        "counts": counts,
        "rows": details,
    }


def confirm_import(
    db: Session,
    *,
    content: bytes,
    expected_sha256: str,
    actor: User,
) -> dict[str, object]:
    actual_sha256 = hashlib.sha256(content).hexdigest()
    if actual_sha256 != expected_sha256.lower():
        raise ApiError("import_hash_mismatch", "文件哈希与预览不一致", 409)
    completed = db.scalar(
        select(EmergencyImport).where(
            EmergencyImport.sha256 == actual_sha256,
            EmergencyImport.status == "completed",
        )
    )
    if completed is not None:
        raise ApiError("import_already_completed", "该应急文件已经导入", 409)
    _document, rows, invalid = parse_export(content)
    counts, _details = classify_rows(db, rows, invalid)
    batch_cache: dict[tuple[date, str], Batch] = {}
    imported = 0
    for row in rows:
        if _find_existing(db, row) is not None:
            continue
        key = (row.event_date, row.batch_display_name)
        batch = batch_cache.get(key)
        if batch is None:
            batch = db.scalar(
                select(Batch).where(
                    Batch.event_date == row.event_date,
                    Batch.display_name == row.batch_display_name,
                )
            )
        if batch is None:
            batch = Batch(
                display_name=row.batch_display_name,
                event_date=row.event_date,
                date_label=row.date_label,
                teacher_label=row.teacher_label,
                fill_date=row.fill_date,
                created_by_id=actor.id,
            )
            db.add(batch)
            db.flush()
        batch_cache[key] = batch
        student = Student(batch_id=batch.id, **row.student)
        db.add(student)
        db.flush()
        evaluation = Evaluation(
            student_id=student.id,
            payload=row.payload,
            schema_version=1,
            recommended_class=str(row.payload.get("recommended_class") or ""),
            created_by_id=actor.id,
            updated_by_id=actor.id,
        )
        db.add(evaluation)
        db.flush()
        write_audit_event(
            db,
            actor_user_id=actor.id,
            action="evaluation_imported",
            target_type="evaluation",
            target_id=evaluation.id,
            target_label=student.name,
            metadata={"import_sha256": actual_sha256},
        )
        imported += 1
    summary = {
        "imported": imported,
        "duplicate": counts["duplicate"],
        "conflict": counts["conflict"],
        "invalid": counts["invalid"],
    }
    db.add(
        EmergencyImport(
            sha256=actual_sha256,
            actor_user_id=actor.id,
            status="completed",
            summary=summary,
            completed_at=datetime.now(UTC),
        )
    )
    write_audit_event(
        db,
        actor_user_id=actor.id,
        action="emergency_import_completed",
        target_type="emergency_import",
        target_label="",
        metadata={"import_sha256": actual_sha256, "counts": summary},
    )
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise ApiError("import_already_completed", "该应急文件已经导入", 409) from None
    return {"sha256": actual_sha256, "counts": summary}
