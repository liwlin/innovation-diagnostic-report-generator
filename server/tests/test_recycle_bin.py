from uuid import UUID

from sqlalchemy import select

from makerseed_app.models import AuditEvent
from tests.support import create_evaluation


def test_teacher_can_trash_and_restore_shared_record(authenticated_client_factory):
    owner = authenticated_client_factory(username="trash-owner")
    teacher = authenticated_client_factory(username="trash-teacher")
    created = create_evaluation(owner)
    evaluation_id = created["evaluation_id"]

    trashed = teacher.client.post(
        f"/api/evaluations/{evaluation_id}/trash",
        headers={"X-CSRF-Token": teacher.csrf},
    )
    assert trashed.status_code == 200
    assert trashed.json()["version"] == created["version"] + 1
    assert teacher.client.get("/api/evaluations").json()["items"] == []
    recycle = teacher.client.get("/api/evaluations", params={"trashed": True}).json()
    assert [item["evaluation_id"] for item in recycle["items"]] == [evaluation_id]

    restored = teacher.client.post(
        f"/api/evaluations/{evaluation_id}/restore",
        headers={"X-CSRF-Token": teacher.csrf},
    )
    assert restored.status_code == 200
    assert restored.json()["version"] == trashed.json()["version"] + 1
    assert teacher.client.get("/api/evaluations", params={"trashed": True}).json()["items"] == []


def test_teacher_cannot_permanently_delete(authenticated_client_factory):
    teacher = authenticated_client_factory()
    created = create_evaluation(teacher)

    response = teacher.client.request(
        "DELETE",
        f"/api/evaluations/{created['evaluation_id']}",
        headers={"X-CSRF-Token": teacher.csrf},
        json={"reason": "监护人书面要求删除"},
    )

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "admin_required"


def test_admin_deletes_only_trashed_record_and_tombstone_survives(
    authenticated_client_factory, db_session
):
    owner = authenticated_client_factory(username="delete-owner")
    admin = authenticated_client_factory(username="delete-admin", role="admin")
    created = create_evaluation(owner, name="待删除学生")
    evaluation_id = created["evaluation_id"]
    url = f"/api/evaluations/{evaluation_id}"

    live_delete = admin.client.request(
        "DELETE",
        url,
        headers={"X-CSRF-Token": admin.csrf},
        json={"reason": "监护人书面要求删除"},
    )
    assert live_delete.status_code == 409
    owner.client.post(f"{url}/trash", headers={"X-CSRF-Token": owner.csrf})

    response = admin.client.request(
        "DELETE",
        url,
        headers={"X-CSRF-Token": admin.csrf},
        json={"reason": "监护人书面要求删除"},
    )

    assert response.status_code == 204
    assert admin.client.get(f"{url}/editor").status_code == 404
    db_session.expire_all()
    tombstone = db_session.scalar(
        select(AuditEvent).where(
            AuditEvent.action == "evaluation_permanently_deleted",
            AuditEvent.target_id == UUID(evaluation_id),
        )
    )
    assert tombstone is not None
    assert tombstone.target_label == ""
    assert tombstone.event_metadata["reason"] == "监护人书面要求删除"


def test_permanent_delete_requires_meaningful_reason(authenticated_client_factory):
    owner = authenticated_client_factory(username="reason-owner")
    admin = authenticated_client_factory(username="reason-admin", role="admin")
    created = create_evaluation(owner)
    owner.client.post(
        f"/api/evaluations/{created['evaluation_id']}/trash",
        headers={"X-CSRF-Token": owner.csrf},
    )

    response = admin.client.request(
        "DELETE",
        f"/api/evaluations/{created['evaluation_id']}",
        headers={"X-CSRF-Token": admin.csrf},
        json={"reason": "  "},
    )

    assert response.status_code == 422
