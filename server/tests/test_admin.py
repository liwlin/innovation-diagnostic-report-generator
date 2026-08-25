from sqlalchemy import select

from makerseed_app.models import Session as UserSession


def test_teacher_cannot_access_user_management(authenticated_client_factory):
    teacher = authenticated_client_factory()

    response = teacher.client.get("/api/admin/users")

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "admin_required"


def test_admin_creates_user_without_returning_password_material(authenticated_client_factory):
    admin = authenticated_client_factory(role="admin")

    response = admin.client.post(
        "/api/admin/users",
        headers={"X-CSRF-Token": admin.csrf},
        json={
            "username": "new-teacher",
            "display_name": "新老师",
            "role": "teacher",
            "password": "new teacher password long enough",
        },
    )

    assert response.status_code == 201
    serialized = response.text.lower()
    assert "password" not in serialized
    assert response.json()["username"] == "new-teacher"


def test_disabling_user_revokes_existing_sessions(authenticated_client_factory, db_session):
    admin = authenticated_client_factory(username="session-admin", role="admin")
    teacher = authenticated_client_factory(username="disable-me")

    response = admin.client.patch(
        f"/api/admin/users/{teacher.user.id}",
        headers={"X-CSRF-Token": admin.csrf},
        json={"is_active": False},
    )

    assert response.status_code == 200
    assert teacher.client.get("/api/session").status_code == 401
    db_session.expire_all()
    sessions = db_session.scalars(
        select(UserSession).where(UserSession.user_id == teacher.user.id)
    ).all()
    assert sessions
    assert all(session.invalidated_at is not None for session in sessions)


def test_last_active_admin_cannot_disable_self(authenticated_client_factory):
    admin = authenticated_client_factory(username="only-admin", role="admin")

    response = admin.client.patch(
        f"/api/admin/users/{admin.user.id}",
        headers={"X-CSRF-Token": admin.csrf},
        json={"is_active": False},
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "last_admin_required"
