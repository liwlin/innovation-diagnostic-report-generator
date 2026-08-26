from __future__ import annotations

import os
from pathlib import Path
from typing import Any


def secure_test_file(path: Path) -> Path:
    if os.name != "nt":
        path.chmod(0o600)
    return path


def cjk_font_path() -> Path:
    env_path = os.environ.get("MKSEED_TEST_CJK_FONT")
    candidates = [
        Path(env_path) if env_path else None,
        Path("/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ]
    for candidate in candidates:
        if candidate is not None and "NotoSansCJK" in candidate.name:
            raise AssertionError("Noto CJK CFF fonts are not compatible with ReportLab.")
        if candidate is not None and candidate.is_file():
            return candidate
    raise AssertionError(
        "No test CJK font found. Install fonts-wqy-zenhei or set MKSEED_TEST_CJK_FONT."
    )


def default_payload(**changes: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "schema_version": 1,
        "mods": [],
        "customMods": [],
        "chart": "radar",
        "rates": [0, 0, 0, 0, 0],
        "skills": [
            {"m": "", "p": "", "r": 0},
            {"m": "", "p": "", "r": 0},
            {"m": "", "p": "", "r": 0},
        ],
        "obs1": "",
        "obs2": "",
        "dir": -1,
        "reason": "",
        "classIndex": "",
        "recommended_class": "",
        "dirCustom": {"name": "", "desc": ""},
        "attendp": "是",
        "talk": "已完成",
        "intent": "高",
        "why": "",
        "ref": "",
        "follow": "",
        "note": "",
        "generated": False,
    }
    payload.update(changes)
    return payload


def create_batch(identity, *, name: str = "批次1", event_date: str = "2026-08-25") -> dict:
    response = identity.client.post(
        "/api/batches",
        headers={"X-CSRF-Token": identity.csrf},
        json={
            "display_name": name,
            "event_date": event_date,
            "date_label": "8月25日",
            "teacher_label": "李老师",
            "fill_date": event_date,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def create_evaluation(
    identity,
    *,
    batch: dict | None = None,
    name: str = "张三",
    grade: str = "三年级",
    recommended_class: str = "头脑风暴1.0 V1",
    payload_changes: dict[str, Any] | None = None,
) -> dict:
    actual_batch = batch or create_batch(identity)
    response = identity.client.post(
        f"/api/batches/{actual_batch['id']}/evaluations",
        headers={"X-CSRF-Token": identity.csrf},
        json={
            "student": {"name": name, "grade": grade, "slot": "批次1 · 上午场"},
            "payload": default_payload(
                recommended_class=recommended_class,
                **(payload_changes or {}),
            ),
        },
    )
    assert response.status_code == 201, response.text
    return response.json()
