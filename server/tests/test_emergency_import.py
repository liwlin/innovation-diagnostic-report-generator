from __future__ import annotations

import hashlib
import json

from sqlalchemy import func, select

from makerseed_app.models import EmergencyImport, Evaluation


def _export_bytes(*, student_name: str = "应急学生", note: str = "") -> bytes:
    payload = {
        "schema_version": 1,
        "exported_at": "2026-08-26T00:00:00Z",
        "source_version": "pages-test",
        "class_list": [{"name": "Python 研习社", "time": "周五"}],
        "promo_text": "课程说明",
        "batches": [
            {
                "id": "legacy-batch",
                "date": "8月26日",
                "teacher": "李老师",
                "fillDate": "2026-08-26",
                "students": [
                    {
                        "id": "legacy-student",
                        "name": student_name,
                        "grade": "三年级",
                        "slot": "批次1 · 上午场",
                        "mods": ["乐高搭建"],
                        "customMods": [],
                        "chart": "radar",
                        "rates": [4, 3, 4, 5, 3],
                        "skills": [
                            {"m": "乐高搭建", "p": "结构稳定", "r": 4},
                            {"m": "", "p": "", "r": 0},
                            {"m": "", "p": "", "r": 0},
                        ],
                        "obs1": "课堂具体表现足够完整",
                        "obs2": "下一步成长建议",
                        "dir": 1,
                        "reason": "推荐理由",
                        "classIndex": "0",
                        "dirCustom": {"name": "", "desc": ""},
                        "attendp": "是",
                        "talk": "已完成",
                        "intent": "高",
                        "why": "",
                        "ref": "",
                        "follow": "",
                        "note": note,
                        "generated": False,
                    }
                ],
            }
        ],
    }
    return json.dumps(payload, ensure_ascii=False).encode()


def _preview(admin, content: bytes):
    return admin.client.post(
        "/api/admin/imports/preview",
        headers={"X-CSRF-Token": admin.csrf},
        files={"file": ("emergency.json", content, "application/json")},
    )


def _confirm(admin, content: bytes, sha256: str):
    return admin.client.post(
        "/api/admin/imports/confirm",
        headers={"X-CSRF-Token": admin.csrf},
        data={"sha256": sha256},
        files={"file": ("emergency.json", content, "application/json")},
    )


def test_preview_is_non_mutating_and_confirm_is_idempotent(
    authenticated_client_factory, db_session
):
    admin = authenticated_client_factory(role="admin")
    content = _export_bytes()
    before = db_session.scalar(select(func.count()).select_from(Evaluation))

    preview = _preview(admin, content)

    assert preview.status_code == 200
    assert preview.json()["counts"] == {"new": 1, "duplicate": 0, "conflict": 0, "invalid": 0}
    assert db_session.scalar(select(func.count()).select_from(Evaluation)) == before
    assert db_session.scalar(select(func.count()).select_from(EmergencyImport)) == 0

    confirmed = _confirm(admin, content, preview.json()["sha256"])
    repeated = _confirm(admin, content, preview.json()["sha256"])

    assert confirmed.status_code == 201
    assert confirmed.json()["counts"]["imported"] == 1
    assert repeated.status_code == 409
    assert repeated.json()["error"]["code"] == "import_already_completed"


def test_preview_distinguishes_duplicate_and_conflict(authenticated_client_factory):
    admin = authenticated_client_factory(role="admin")
    original = _export_bytes(note="原始备注")
    first = _preview(admin, original).json()
    assert _confirm(admin, original, first["sha256"]).status_code == 201

    duplicate = _preview(admin, original)
    conflict = _preview(admin, _export_bytes(note="不同备注"))

    assert duplicate.json()["counts"]["duplicate"] == 1
    assert conflict.json()["counts"]["conflict"] == 1


def test_teacher_cannot_import_and_secret_fields_are_rejected(authenticated_client_factory):
    teacher = authenticated_client_factory()
    content = _export_bytes()
    denied = teacher.client.post(
        "/api/admin/imports/preview",
        headers={"X-CSRF-Token": teacher.csrf},
        files={"file": ("emergency.json", content, "application/json")},
    )
    assert denied.status_code == 403

    admin = authenticated_client_factory(role="admin")
    unsafe = json.loads(content)
    unsafe["apiKey"] = "secret"
    rejected = _preview(admin, json.dumps(unsafe).encode())
    assert rejected.status_code == 422
    assert rejected.json()["error"]["code"] == "invalid_import"


def test_confirm_rejects_hash_mismatch(authenticated_client_factory):
    admin = authenticated_client_factory(role="admin")
    content = _export_bytes()

    response = _confirm(admin, content, hashlib.sha256(b"different").hexdigest())

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "import_hash_mismatch"
