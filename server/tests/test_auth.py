from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from makerseed_app.security.rate_limit import as_utc


def _cookie_header(response, name: str) -> str:
    return next(
        value for value in response.headers.get_list("set-cookie") if value.startswith(name)
    )


def _login(client, username: str = "teacher", password: str = "correct horse battery staple"):
    return client.post("/api/auth/login", json={"username": username, "password": password})


def test_password_hash_is_not_plaintext_and_verifies():
    from makerseed_app.security.passwords import hash_password, verify_password

    encoded = hash_password("correct horse battery staple")

    assert encoded != "correct horse battery staple"
    assert verify_password("correct horse battery staple", encoded) is True
    assert verify_password("wrong password", encoded) is False


def test_login_sets_secure_session_and_csrf_cookies(client, teacher):
    response = _login(client)

    assert response.status_code == 200
    assert response.json()["user"] == {
        "id": str(teacher.id),
        "username": "teacher",
        "display_name": "李老师",
        "role": "teacher",
    }
    session_cookie = _cookie_header(response, "mkseed_session=")
    csrf_cookie = _cookie_header(response, "mkseed_csrf=")
    assert "HttpOnly" in session_cookie
    assert "SameSite=lax" in session_cookie
    assert "Path=/" in session_cookie
    assert "HttpOnly" not in csrf_cookie
    assert "SameSite=lax" in csrf_cookie


def test_session_endpoint_uses_opaque_cookie(client, teacher):
    assert _login(client).status_code == 200

    response = client.get("/api/session")

    assert response.status_code == 200
    assert response.json()["user"]["id"] == str(teacher.id)
    assert "token" not in json.dumps(response.json()).lower()


def test_state_change_without_csrf_is_rejected(client, teacher):
    assert _login(client).status_code == 200

    response = client.post("/api/auth/logout")

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "csrf_failed"


def test_logout_with_csrf_invalidates_session(client, teacher):
    assert _login(client).status_code == 200
    csrf = client.cookies.get("mkseed_csrf")
    assert csrf

    response = client.post("/api/auth/logout", headers={"X-CSRF-Token": csrf})

    assert response.status_code == 204
    assert client.get("/api/session").status_code == 401


def test_five_wrong_passwords_lock_account_and_redact_audit(client, teacher, db_session):
    for _attempt in range(4):
        response = _login(client, password="wrong password")
        assert response.status_code == 401

    fifth = _login(client, password="wrong password")
    assert fifth.status_code == 429
    locked = _login(client)
    assert locked.status_code == 429

    from makerseed_app.models import AuditEvent, User

    db_session.expire_all()
    user = db_session.scalar(select(User).where(User.id == teacher.id))
    assert user is not None
    assert user.failed_login_count == 5
    assert user.locked_until is not None
    events = db_session.scalars(select(AuditEvent).where(AuditEvent.action == "login_failed")).all()
    serialized = json.dumps([event.event_metadata for event in events], ensure_ascii=False)
    assert "wrong password" not in serialized
    assert "correct horse battery staple" not in serialized


def test_disabled_user_cannot_login(client, teacher, db_session):
    teacher.is_active = False
    db_session.commit()

    response = _login(client)

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "account_disabled"


def test_expired_session_is_rejected(client, teacher, db_session):
    assert _login(client).status_code == 200

    from makerseed_app.models import Session
    session = db_session.scalar(select(Session).where(Session.user_id == teacher.id))
    assert session is not None
    session.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    db_session.commit()

    response = client.get("/api/session")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"


def test_idle_session_timeout_uses_last_seen_at(client, teacher, db_session, settings):
    settings.session_idle_timeout_minutes = 30
    assert _login(client).status_code == 200

    from makerseed_app.models import Session

    session = db_session.scalar(select(Session).where(Session.user_id == teacher.id))
    assert session is not None
    session.last_seen_at = datetime.now(UTC) - timedelta(minutes=31)
    db_session.commit()

    response = client.get("/api/session")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"


def test_active_session_last_seen_updates_only_after_throttle(
    client, teacher, db_session, settings
):
    settings.session_idle_timeout_minutes = 30
    settings.session_touch_throttle_seconds = 300
    assert _login(client).status_code == 200

    from makerseed_app.models import Session

    session = db_session.scalar(select(Session).where(Session.user_id == teacher.id))
    assert session is not None
    recent = datetime.now(UTC) - timedelta(seconds=30)
    session.last_seen_at = recent
    db_session.commit()

    assert client.get("/api/session").status_code == 200
    db_session.expire_all()
    session = db_session.scalar(select(Session).where(Session.user_id == teacher.id))
    assert session is not None
    assert as_utc(session.last_seen_at) == recent

    stale = datetime.now(UTC) - timedelta(minutes=6)
    session.last_seen_at = stale
    db_session.commit()

    assert client.get("/api/session").status_code == 200
    db_session.expire_all()
    session = db_session.scalar(select(Session).where(Session.user_id == teacher.id))
    assert session is not None
    assert as_utc(session.last_seen_at) > stale


def test_disabling_user_invalidates_an_existing_session(client, teacher, db_session):
    assert _login(client).status_code == 200
    teacher.is_active = False
    db_session.commit()

    response = client.get("/api/session")

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "authentication_required"
