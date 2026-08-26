from __future__ import annotations

import sys
from collections.abc import Callable
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.support import cjk_font_path

SERVER_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = SERVER_ROOT / "src"
sys.path.insert(0, str(SRC_ROOT))


@dataclass(frozen=True)
class AuthenticatedClient:
    client: TestClient
    user: object
    csrf: str


@pytest.fixture
def settings(tmp_path):
    from makerseed_app.config import Settings

    report_root = tmp_path / "reports"
    report_root.mkdir()
    project_root = Path(__file__).resolve().parents[2]
    return Settings(
        environment="test",
        app_version="test",
        database_url="sqlite+pysqlite:///:memory:",
        secure_cookies=False,
        session_secret="test-session-secret-that-is-long-enough",
        bootstrap_secret="test-bootstrap-secret-that-is-long-enough",
        report_root=report_root,
        report_font_path=cjk_font_path(),
        logo_mark_path=project_root / "assets" / "logo-mark.png",
        logo_lockup_path=project_root / "assets" / "logo-lockup.png",
        promo_text="测试课程说明",
    )


@pytest.fixture
def app(settings):
    from makerseed_app.main import create_app
    from makerseed_app.models import Base

    application = create_app(settings)
    Base.metadata.create_all(application.state.engine)
    yield application
    Base.metadata.drop_all(application.state.engine)
    application.state.engine.dispose()


@pytest.fixture
def client(app):
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def db_session(app):
    session = app.state.session_factory()
    try:
        yield session
    finally:
        session.close()


@pytest.fixture
def teacher(db_session):
    from makerseed_app.models import User
    from makerseed_app.security.passwords import hash_password

    user = User(
        username="teacher",
        display_name="李老师",
        role="teacher",
        password_hash=hash_password("correct horse battery staple"),
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


@pytest.fixture
def admin(db_session):
    from makerseed_app.models import User
    from makerseed_app.security.passwords import hash_password

    user = User(
        username="admin",
        display_name="管理员",
        role="admin",
        password_hash=hash_password("admin correct horse battery staple"),
    )
    db_session.add(user)
    db_session.commit()
    db_session.refresh(user)
    return user


@pytest.fixture
def authenticated_client_factory(app) -> Callable[..., AuthenticatedClient]:
    from makerseed_app.models import User
    from makerseed_app.security.passwords import hash_password

    stack = ExitStack()
    sequence = 0

    def create(*, username: str | None = None, role: str = "teacher") -> AuthenticatedClient:
        nonlocal sequence
        sequence += 1
        actual_username = username or f"teacher{sequence}"
        password = f"fixture password {sequence} with sufficient length"
        with app.state.session_factory() as session:
            user = User(
                username=actual_username,
                display_name=f"测试老师{sequence}",
                role=role,
                password_hash=hash_password(password),
            )
            session.add(user)
            session.commit()
            session.refresh(user)
            session.expunge(user)
        test_client = stack.enter_context(TestClient(app))
        response = test_client.post(
            "/api/auth/login", json={"username": actual_username, "password": password}
        )
        assert response.status_code == 200
        csrf = test_client.cookies.get("mkseed_csrf")
        assert csrf
        return AuthenticatedClient(test_client, user, csrf)

    yield create
    stack.close()
