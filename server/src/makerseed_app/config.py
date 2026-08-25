from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["development", "test", "production"]


def load_secret(path: Path) -> str:
    if not path.is_file():
        raise ValueError(f"required secret file is missing: {path.name}")
    value = path.read_text(encoding="utf-8").rstrip("\r\n")
    if value == "":
        raise ValueError(f"secret file is empty: {path.name}")
    return value


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="MKSEED_", extra="forbid")

    environment: Environment = "development"
    app_version: str = "dev"
    database_url: SecretStr = SecretStr("sqlite+pysqlite:///:memory:")
    session_secret: SecretStr | None = None
    bootstrap_secret: SecretStr | None = None
    secrets_dir: Path | None = None
    secure_cookies: bool = True
    session_cookie_name: str = "mkseed_session"
    csrf_cookie_name: str = "mkseed_csrf"

    @model_validator(mode="after")
    def load_production_secrets(self) -> Settings:
        if self.environment != "production":
            return self
        if self.secrets_dir is None:
            raise ValueError("production secret file directory is required")
        self.database_url = SecretStr(load_secret(self.secrets_dir / "database_url"))
        self.session_secret = SecretStr(load_secret(self.secrets_dir / "session_secret"))
        self.bootstrap_secret = SecretStr(load_secret(self.secrets_dir / "bootstrap_secret"))
        return self

