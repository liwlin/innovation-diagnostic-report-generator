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
def client(settings):
    from makerseed_app.main import create_app

    with TestClient(create_app(settings)) as test_client:
        yield test_client
