from __future__ import annotations

import secrets

from fastapi import Request

from ..errors import ApiError


def require_csrf(request: Request) -> None:
    settings = request.app.state.settings
    cookie_value = request.cookies.get(settings.csrf_cookie_name, "")
    header_value = request.headers.get("X-CSRF-Token", "")
    if (
        not cookie_value
        or not header_value
        or not secrets.compare_digest(cookie_value, header_value)
    ):
        raise ApiError("csrf_failed", "请求校验失败，请刷新页面后重试", 403)
