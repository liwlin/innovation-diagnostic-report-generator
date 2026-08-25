from sqlalchemy import func, select

from makerseed_app.models import AuditEvent, EvaluationVersion
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
