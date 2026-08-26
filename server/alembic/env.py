from __future__ import annotations

import os
from logging.config import fileConfig
from pathlib import Path

from sqlalchemy import engine_from_config, pool

from alembic import context
from makerseed_app.models import Base

config = context.config
owner_url_file = os.environ.get("MKSEED_MIGRATION_DATABASE_URL_FILE")
if owner_url_file:
    owner_path = Path(owner_url_file)
    if not owner_path.is_file() or owner_path.is_symlink():
        raise RuntimeError("migration database URL file is missing or unsafe")
    owner_url = owner_path.read_text(encoding="utf-8").rstrip("\r\n")
    if not owner_url:
        raise RuntimeError("migration database URL file is empty")
    config.set_main_option("sqlalchemy.url", owner_url.replace("%", "%%"))
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
