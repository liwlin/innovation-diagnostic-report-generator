from __future__ import annotations

import json
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse, HTMLResponse, Response
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import Response as StarletteResponse
from starlette.staticfiles import StaticFiles

from .config import Settings

SHELL_CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
    "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)
EDITOR_CSP = (
    "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; "
    "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' https:; "
    "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(
        self, request: Request, call_next: RequestResponseEndpoint
    ) -> StarletteResponse:
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "same-origin"
        response.headers["Content-Security-Policy"] = (
            EDITOR_CSP if request.url.path == "/editor" else SHELL_CSP
        )
        return response


def _require_file(path: Path) -> Path:
    if not path.is_file():
        raise RuntimeError(f"required static file is missing: {path.name}")
    return path


def register_static_routes(app: FastAPI, settings: Settings) -> None:
    static_root = settings.static_root.resolve()
    nas_web_root = settings.nas_web_root.resolve()
    shell_path = _require_file(nas_web_root / "index.html")
    editor_path = _require_file(static_root / "科创方向诊断报告生成器.dc.html")

    app.mount("/assets", StaticFiles(directory=static_root / "assets"), name="assets")
    app.mount("/shared", StaticFiles(directory=static_root / "shared"), name="shared")
    app.mount("/nas-static", StaticFiles(directory=nas_web_root), name="nas-static")

    @app.get("/", include_in_schema=False)
    def shell() -> FileResponse:
        return FileResponse(shell_path, media_type="text/html")

    @app.get("/runtime-config.js", include_in_schema=False)
    def runtime_config() -> Response:
        payload = {
            "storageMode": "api",
            "apiBaseUrl": "",
            "appVersion": settings.app_version,
            "commitSha": "",
        }
        serialized = json.dumps(payload, separators=(",", ":"))
        body = f"window.__MKSEED_RUNTIME__=Object.freeze({serialized});"
        return Response(body, media_type="text/javascript", headers={"Cache-Control": "no-store"})

    @app.get("/editor", include_in_schema=False)
    def editor() -> HTMLResponse:
        source = editor_path.read_text(encoding="utf-8")
        marker = '<script src="./shared/runtime-config.js"></script>'
        if marker not in source:
            raise RuntimeError("editor runtime marker is missing")
        source = source.replace(
            marker,
            '<script src="/runtime-config.js"></script>\n' + marker,
            1,
        )
        return HTMLResponse(source)

    @app.get("/support.js", include_in_schema=False)
    def support_js() -> FileResponse:
        return FileResponse(_require_file(static_root / "support.js"), media_type="text/javascript")

    @app.get("/doc-page.js", include_in_schema=False)
    def doc_page_js() -> FileResponse:
        return FileResponse(
            _require_file(static_root / "doc-page.js"), media_type="text/javascript"
        )
