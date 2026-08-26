from __future__ import annotations

import os
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.exc import ProgrammingError

RUNTIME_URL = os.environ.get("MKSEED_POSTGRES_RUNTIME_TEST_URL")
pytestmark = pytest.mark.skipif(
    not RUNTIME_URL,
    reason="requires the isolated PostgreSQL runtime-role URL",
)


def test_runtime_role_can_insert_but_cannot_modify_or_delete_audit_rows():
    event_id = uuid4()
    engine = create_engine(RUNTIME_URL)
    with engine.begin() as connection:
        inserted_id = connection.scalar(
            text(
                """
                INSERT INTO audit_events
                    (id, actor_user_id, action, target_type, target_id, target_label,
                     event_metadata, created_at)
                VALUES
                    (:id, NULL, 'grant_probe', 'system', NULL, '', '{}'::jsonb, now())
                RETURNING id
                """
            ),
            {"id": event_id},
        )
    assert inserted_id == event_id
    with pytest.raises(ProgrammingError), engine.begin() as connection:
        connection.execute(
            text("UPDATE audit_events SET action='tampered' WHERE id=:id"),
            {"id": event_id},
        )
    with pytest.raises(ProgrammingError), engine.begin() as connection:
        connection.execute(text("DELETE FROM audit_events WHERE id=:id"), {"id": event_id})
