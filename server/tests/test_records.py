from datetime import date, datetime
from pathlib import Path
from uuid import UUID

import pytest
from sqlalchemy import func, select

from makerseed_app.models import AuditEvent, Evaluation, EvaluationVersion, GenerationRecord, User
from makerseed_app.reports.storage import ReportStorage
from makerseed_app.services import records as record_service
from tests.support import create_evaluation, default_payload


def test_unauthenticated_record_list_is_rejected(client):
    response = client.get("/api/evaluations")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"


def test_teacher_can_read_and_update_another_teachers_record(
    authenticated_client_factory, db_session
):
    teacher_a = authenticated_client_factory(username="teacher-a")
    teacher_b = authenticated_client_factory(username="teacher-b")
    created = create_evaluation(teacher_a)

    get_response = teacher_b.client.get(f"/api/evaluations/{created['evaluation_id']}/editor")
    assert get_response.status_code == 200
    body = get_response.json()
    body["payload"]["obs1"] = "补充后的课堂具体表现"
    put_response = teacher_b.client.put(
        f"/api/evaluations/{created['evaluation_id']}",
        headers={"X-CSRF-Token": teacher_b.csrf},
        json={"version": body["version"], "student": body["student"], "payload": body["payload"]},
    )

    assert put_response.status_code == 200
    updated = put_response.json()
    assert updated["payload"]["obs1"] == "补充后的课堂具体表现"
    assert updated["version"] == body["version"] + 1
    assert updated["updated_by"]["id"] == str(teacher_b.user.id)
    assert db_session.scalar(select(func.count()).select_from(EvaluationVersion)) == 1
    actions = db_session.scalars(select(AuditEvent.action)).all()
    assert "evaluation_created" in actions
    assert "evaluation_updated" in actions


def test_invalid_rates_shape_is_rejected(authenticated_client_factory):
    teacher = authenticated_client_factory()
    created = create_evaluation(teacher)
    editor = teacher.client.get(f"/api/evaluations/{created['evaluation_id']}/editor").json()

    response = teacher.client.put(
        f"/api/evaluations/{created['evaluation_id']}",
        headers={"X-CSRF-Token": teacher.csrf},
        json={
            "version": editor["version"],
            "student": editor["student"],
            "payload": default_payload(rates=[1, 2]),
        },
    )

    assert response.status_code == 422


def test_permanent_delete_restores_quarantined_files_when_db_commit_fails(
    authenticated_client_factory, db_session, tmp_path: Path, monkeypatch
):
    owner = authenticated_client_factory(username="rollback-owner")
    admin = authenticated_client_factory(username="rollback-admin", role="admin")
    created = create_evaluation(owner)
    evaluation_id = UUID(created["evaluation_id"])
    owner.client.post(
        f"/api/evaluations/{evaluation_id}/trash",
        headers={"X-CSRF-Token": owner.csrf},
    )
    storage = ReportStorage(tmp_path)
    report_dir = storage.resolve_generation_dir(
        event_date=date.fromisoformat(created["batch"]["event_date"]),
        batch_name=created["batch"]["display_name"],
        student_name=created["student"]["name"],
        generated_at=datetime.fromisoformat(created["updated_at"]).time(),
    )
    report_path = storage.write_atomic(report_dir, "报告.pdf", b"db-rollback").path
    job = GenerationRecord(
        evaluation_id=evaluation_id,
        created_by_id=owner.user.id,
        status="completed",
        input_snapshot={},
        renderer_version="test",
        artifact_manifest={
            "artifacts": [
                {
                    "id": "without-pdf",
                    "variant": "without",
                    "format": "pdf",
                    "relative_path": report_path.relative_to(tmp_path).as_posix(),
                    "sha256": "0" * 64,
                    "size": report_path.stat().st_size,
                    "mime": "application/pdf",
                }
            ]
        },
    )
    db_session.add(job)
    db_session.commit()
    actor = db_session.get(User, admin.user.id)
    assert actor is not None

    real_commit = db_session.commit
    commit_calls = 0

    def fail_delete_commit() -> None:
        nonlocal commit_calls
        commit_calls += 1
        if commit_calls == 1:
            raise RuntimeError("simulated commit failure")
        real_commit()

    monkeypatch.setattr(db_session, "commit", fail_delete_commit)

    with pytest.raises(RuntimeError, match="simulated commit failure"):
        record_service.permanently_delete_evaluation(
            db_session,
            evaluation_id=evaluation_id,
            reason="验证事务失败回滚",
            actor=actor,
            storage=storage,
        )

    assert report_path.read_bytes() == b"db-rollback"
    db_session.rollback()
    db_session.expire_all()
    assert db_session.get(Evaluation, evaluation_id) is not None
