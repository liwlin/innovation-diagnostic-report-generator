from __future__ import annotations

from fastapi import FastAPI

from .config import Settings
from .errors import ApiError, api_error_handler


def create_app(settings: Settings | None = None) -> FastAPI:
    app_settings = settings or Settings()
    docs_enabled = app_settings.environment != "production"
    app = FastAPI(
        title="MakerSeed Diagnostic API",
        docs_url="/docs" if docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if docs_enabled else None,
    )
    app.state.settings = app_settings
    app.add_exception_handler(ApiError, api_error_handler)

    @app.get("/api/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "version": app_settings.app_version}

    return app


app = create_app()
