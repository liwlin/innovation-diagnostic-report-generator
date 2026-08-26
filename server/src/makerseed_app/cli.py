from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

from sqlalchemy import func, select

from .config import Settings
from .database import SessionFactory, build_engine, build_session_factory
from .models import User
from .security.passwords import hash_password
from .services.audit import write_audit_event

USERNAME = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")


class BootstrapRefused(RuntimeError):
    pass


def _read_bootstrap_password(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise BootstrapRefused("bootstrap password file is missing or unsafe")
    if os.name != "nt" and path.stat().st_mode & 0o077:
        raise BootstrapRefused("bootstrap password file must not be group/world accessible")
    password = path.read_text(encoding="utf-8").rstrip("\r\n")
    if len(password) < 12:
        raise BootstrapRefused("bootstrap password must contain at least 12 characters")
    return password


def bootstrap_admin(
    settings: Settings,
    *,
    username: str,
    display_name: str,
    password_file: Path,
    session_factory: SessionFactory | None = None,
) -> User:
    normalized_username = username.strip().lower()
    normalized_display_name = display_name.strip()
    if not USERNAME.fullmatch(normalized_username):
        raise BootstrapRefused("bootstrap username is invalid")
    if not normalized_display_name or len(normalized_display_name) > 120:
        raise BootstrapRefused("bootstrap display name is invalid")
    password = _read_bootstrap_password(password_file)

    engine = None
    factory = session_factory
    if factory is None:
        engine = build_engine(settings)
        factory = build_session_factory(engine)
    try:
        with factory() as db:
            admin_count = int(
                db.scalar(select(func.count()).select_from(User).where(User.role == "admin")) or 0
            )
            if admin_count:
                raise BootstrapRefused("an administrator already exists")
            user = User(
                username=normalized_username,
                display_name=normalized_display_name,
                role="admin",
                password_hash=hash_password(password),
            )
            db.add(user)
            db.flush()
            write_audit_event(
                db,
                actor_user_id=user.id,
                action="bootstrap_admin_created",
                target_type="user",
                target_id=user.id,
                target_label=user.username,
                metadata={"role": "admin"},
            )
            db.commit()
            db.refresh(user)
            db.expunge(user)
            return user
    finally:
        if engine is not None:
            engine.dispose()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="makerseed-admin", allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    bootstrap = commands.add_parser("bootstrap-admin", allow_abbrev=False)
    bootstrap.add_argument("--username", required=True)
    bootstrap.add_argument("--display-name", required=True)
    bootstrap.add_argument("--password-file", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "bootstrap-admin":
        try:
            user = bootstrap_admin(
                Settings(),
                username=args.username,
                display_name=args.display_name,
                password_file=args.password_file,
            )
        except BootstrapRefused as error:
            print(f"bootstrap refused: {error}")
            return 2
        print(f"administrator created: {user.username}")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
