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
    session_ttl_minutes: int = 480
    max_failed_logins: int = 5
    lockout_minutes: int = 15
    generation_worker_enabled: bool = False
    generation_poll_seconds: float = 2.0
    report_root: Path = Path("var/reports")
    report_font_path: Path = Path("assets/fonts/NotoSansCJK-Regular.ttc")
    logo_mark_path: Path = Path("assets/logo-mark.png")
    logo_lockup_path: Path = Path("assets/logo-lockup.png")
    filename_pattern: str = "{name}_{date}_科创体验报告"
    promo_text: str = ""
    static_root: Path = Path(".")
    nas_web_root: Path = Path("nas-web")

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
