from __future__ import annotations

import json
from uuid import UUID

from sqlalchemy import select

from makerseed_app.models import AuditEvent
from tests.support import create_evaluation


def test_ai_use_audit_accepts_only_sanitized_metadata(authenticated_client_factory, db_session):
    teacher = authenticated_client_factory()
    evaluation = create_evaluation(teacher)

    response = teacher.client.post(
        "/api/events/ai-use",
        headers={"X-CSRF-Token": teacher.csrf},
        json={
            "evaluation_id": evaluation["evaluation_id"],
            "provider_host": "api.deepseek.com",
            "model": "deepseek-chat",
            "field_key": "obs1",
            "duration_ms": 321,
            "success": True,
        },
    )

    assert response.status_code == 204
    db_session.expire_all()
    event = db_session.scalar(
        select(AuditEvent).where(
            AuditEvent.action == "ai_polish_used",
            AuditEvent.target_id == UUID(evaluation["evaluation_id"]),
        )
    )
    assert event is not None
    assert event.event_metadata == {
        "provider_host": "api.deepseek.com",
        "model": "deepseek-chat",
        "field_key": "obs1",
        "duration_ms": 321,
        "outcome": "success",
    }
    serialized = json.dumps(event.event_metadata).lower()
    for forbidden in ("api_key", "apikey", "authorization", "prompt", "response_text"):
        assert forbidden not in serialized


def test_ai_use_audit_rejects_url_and_secret_fields(authenticated_client_factory):
    teacher = authenticated_client_factory()
    base = {
        "evaluation_id": "11111111-1111-4111-8111-111111111111",
        "provider_host": "https://api.deepseek.com/path?key=secret",
        "model": "deepseek-chat",
        "field_key": "obs1",
        "duration_ms": 20,
        "success": False,
    }

    url_rejected = teacher.client.post(
        "/api/events/ai-use",
        headers={"X-CSRF-Token": teacher.csrf},
        json=base,
    )
    secret_rejected = teacher.client.post(
        "/api/events/ai-use",
        headers={"X-CSRF-Token": teacher.csrf},
        json={**base, "provider_host": "api.deepseek.com", "api_key": "secret"},
    )

    assert url_rejected.status_code == 422
    assert secret_rejected.status_code == 422
