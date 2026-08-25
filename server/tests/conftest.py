from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

SERVER_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = SERVER_ROOT / "src"
sys.path.insert(0, str(SRC_ROOT))


@pytest.fixture
def settings():
    from makerseed_app.config import Settings

    return Settings(
        environment="test",
        app_version="test",
        database_url="sqlite+pysqlite:///:memory:",
        secure_cookies=False,
        session_secret="test-session-secret-that-is-long-enough",
        bootstrap_secret="test-bootstrap-secret-that-is-long-enough",
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
