from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import timedelta

from fastapi import FastAPI

from .api.admin import router as admin_router
from .api.auth import router as auth_router
from .api.records import router as records_router
from .config import Settings
from .database import build_engine, build_session_factory
from .errors import ApiError, api_error_handler
from .reports.jobs import GenerationJobSettings, GenerationWorker, recover_stale_jobs
from .reports.renderer import RenderAssets


def create_app(settings: Settings | None = None) -> FastAPI:
    app_settings = settings or Settings()
    docs_enabled = app_settings.environment != "production"

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        worker: GenerationWorker | None = None
        task: asyncio.Task[None] | None = None
        if app_settings.generation_worker_enabled:
            job_settings = GenerationJobSettings(
                report_root=app_settings.report_root,
                assets=RenderAssets(
                    font_path=app_settings.report_font_path,
                    logo_mark_path=app_settings.logo_mark_path,
                    logo_lockup_path=app_settings.logo_lockup_path,
                ),
                renderer_version=app_settings.app_version,
                filename_pattern=app_settings.filename_pattern,
                promo_text=app_settings.promo_text,
            )
            with app.state.session_factory() as db:
                recover_stale_jobs(db, stale_after=timedelta(minutes=10))
            worker = GenerationWorker(app.state.session_factory, job_settings)
            task = asyncio.create_task(
                worker.run(poll_seconds=app_settings.generation_poll_seconds),
                name="makerseed-generation-worker",
            )
        app.state.generation_worker = worker
        app.state.generation_worker_task = task
        try:
            yield
        finally:
            if worker is not None and task is not None:
                worker.stop()
                await task

    app = FastAPI(
        title="MakerSeed Diagnostic API",
        docs_url="/docs" if docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if docs_enabled else None,
        lifespan=lifespan,
    )
    app.state.settings = app_settings
    app.state.engine = build_engine(app_settings)
    app.state.session_factory = build_session_factory(app.state.engine)
    app.add_exception_handler(ApiError, api_error_handler)
    app.include_router(admin_router)
    app.include_router(auth_router)
    app.include_router(records_router)

    @app.get("/api/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "version": app_settings.app_version}

    return app


app = create_app()
