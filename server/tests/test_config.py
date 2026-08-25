from pathlib import Path

import pytest


def test_production_rejects_missing_secret_files(tmp_path: Path):
    from makerseed_app.config import Settings

    with pytest.raises(ValueError, match="secret file"):
        Settings(environment="production", secrets_dir=tmp_path)


def test_secret_loader_strips_only_line_endings(tmp_path: Path):
    from makerseed_app.config import load_secret

    secret_file = tmp_path / "session_secret"
    secret_file.write_text("  keep surrounding spaces  \r\n", encoding="utf-8")

    assert load_secret(secret_file) == "  keep surrounding spaces  "


def test_secret_loader_rejects_empty_file(tmp_path: Path):
    from makerseed_app.config import load_secret

    secret_file = tmp_path / "empty"
    secret_file.write_text("\n", encoding="utf-8")

    with pytest.raises(ValueError, match="empty"):
        load_secret(secret_file)
