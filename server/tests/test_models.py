from pathlib import Path
from uuid import UUID

from alembic.config import Config
from sqlalchemy import create_engine, inspect

from alembic import command

REQUIRED_TABLES = {
    "users",
    "sessions",
    "batches",
    "students",
    "evaluations",
    "evaluation_versions",
    "generation_records",
    "audit_events",
    "emergency_imports",
}


def test_initial_schema_contains_required_tables(settings):
    from makerseed_app.database import build_engine
    from makerseed_app.models import Base

    engine = build_engine(settings)
    Base.metadata.create_all(engine)

    assert set(inspect(engine).get_table_names()) == REQUIRED_TABLES


def test_evaluation_version_is_required_and_search_columns_are_indexed(settings):
    from makerseed_app.database import build_engine
    from makerseed_app.models import Base

    engine = build_engine(settings)
    Base.metadata.create_all(engine)
    inspector = inspect(engine)

    columns = {column["name"]: column for column in inspector.get_columns("evaluations")}
    assert columns["version"]["nullable"] is False

    indexed_columns = {
        column for index in inspector.get_indexes("evaluations") for column in index["column_names"]
    }
    assert {"recommended_class", "deleted_at", "updated_by_id"} <= indexed_columns


def test_audit_target_id_is_not_a_foreign_key(settings):
    from makerseed_app.database import build_engine
    from makerseed_app.models import Base

    engine = build_engine(settings)
    Base.metadata.create_all(engine)

    foreign_key_columns = {
        column
        for foreign_key in inspect(engine).get_foreign_keys("audit_events")
        for column in foreign_key["constrained_columns"]
    }
    assert "actor_user_id" in foreign_key_columns
    assert "target_id" not in foreign_key_columns


def test_generation_status_constraint_rejects_unknown_value(settings):
    from sqlalchemy import insert
    from sqlalchemy.exc import IntegrityError

    from makerseed_app.database import build_engine
    from makerseed_app.models import Base, GenerationRecord

    engine = build_engine(settings)
    Base.metadata.create_all(engine)

    try:
        with engine.begin() as connection:
            connection.execute(
                insert(GenerationRecord).values(
                    evaluation_id=UUID("00000000-0000-0000-0000-000000000001"),
                    created_by_id=UUID("00000000-0000-0000-0000-000000000002"),
                    status="unknown",
                    input_snapshot={},
                    renderer_version="test",
                    artifact_manifest={},
                )
            )
    except IntegrityError:
        pass
    else:
        raise AssertionError("unknown generation status was accepted")


def test_alembic_upgrade_creates_required_schema(tmp_path: Path):
    server_root = Path(__file__).resolve().parents[1]
    database_path = tmp_path / "migration.sqlite3"
    config = Config(server_root / "alembic.ini")
    config.set_main_option("sqlalchemy.url", f"sqlite:///{database_path.as_posix()}")

    command.upgrade(config, "head")

    engine = create_engine(f"sqlite:///{database_path.as_posix()}")
    assert set(inspect(engine).get_table_names()) == REQUIRED_TABLES | {"alembic_version"}
