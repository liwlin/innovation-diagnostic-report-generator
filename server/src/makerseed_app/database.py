from __future__ import annotations

from collections.abc import Generator, Iterator
from contextlib import contextmanager

from fastapi import Request
from sqlalchemy import Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from .config import Settings

SessionFactory = sessionmaker[Session]


def build_engine(settings: Settings) -> Engine:
    database_url = settings.database_url.get_secret_value()
    options: dict[str, object] = {"pool_pre_ping": True}
    if database_url == "sqlite+pysqlite:///:memory:":
        options.update(
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
    engine = create_engine(database_url, **options)
    if database_url.startswith("sqlite"):
        event.listen(engine, "connect", _enable_sqlite_foreign_keys)
    return engine


def _enable_sqlite_foreign_keys(dbapi_connection: object, _connection_record: object) -> None:
    cursor = dbapi_connection.cursor()  # type: ignore[attr-defined]
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()


def build_session_factory(engine: Engine) -> SessionFactory:
    return sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


@contextmanager
def session_scope(factory: SessionFactory) -> Iterator[Session]:
    session = factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def get_db(request: Request) -> Generator[Session, None, None]:
    factory: SessionFactory = request.app.state.session_factory
    session = factory()
    try:
        yield session
    finally:
        session.close()
