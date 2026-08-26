from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy import func, select

from makerseed_app.models import User


def test_bootstrap_admin_reads_password_file_and_creates_one_admin(
    settings, app, db_session, tmp_path: Path, capsys
):
    from makerseed_app.cli import bootstrap_admin

    password_file = tmp_path / "bootstrap_password"
    password_file.write_text("Bootstrap password 2026\n", encoding="utf-8")

    created = bootstrap_admin(
        settings,
        username="first-admin",
        display_name="首位管理员",
        password_file=password_file,
        session_factory=app.state.session_factory,
    )

    assert created.username == "first-admin"
    assert created.role == "admin"
    assert db_session.scalar(select(func.count()).select_from(User)) == 1
    output = capsys.readouterr()
    assert "Bootstrap password 2026" not in output.out + output.err


def test_bootstrap_admin_refuses_second_initialization(settings, app, tmp_path: Path):
    from makerseed_app.cli import BootstrapRefused, bootstrap_admin

    password_file = tmp_path / "bootstrap_password"
    password_file.write_text("Bootstrap password 2026", encoding="utf-8")
    bootstrap_admin(
        settings,
        username="first-admin",
        display_name="首位管理员",
        password_file=password_file,
        session_factory=app.state.session_factory,
    )

    with pytest.raises(BootstrapRefused, match="already exists"):
        bootstrap_admin(
            settings,
            username="second-admin",
            display_name="第二管理员",
            password_file=password_file,
            session_factory=app.state.session_factory,
        )


def test_cli_has_no_plaintext_password_argument():
    from makerseed_app.cli import build_parser

    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(
            [
                "bootstrap-admin",
                "--username",
                "admin",
                "--display-name",
                "管理员",
                "--password",
                "plain-text-is-forbidden",
            ]
        )


def test_bootstrap_rejects_short_or_missing_password_file(settings, app, tmp_path: Path):
    from makerseed_app.cli import BootstrapRefused, bootstrap_admin

    with pytest.raises(BootstrapRefused, match="password file"):
        bootstrap_admin(
            settings,
            username="admin",
            display_name="管理员",
            password_file=tmp_path / "missing",
            session_factory=app.state.session_factory,
        )
    short_file = tmp_path / "short"
    short_file.write_text("too-short", encoding="utf-8")
    with pytest.raises(BootstrapRefused, match="12 characters"):
        bootstrap_admin(
            settings,
            username="admin",
            display_name="管理员",
            password_file=short_file,
            session_factory=app.state.session_factory,
        )
