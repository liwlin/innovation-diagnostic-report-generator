from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, UploadFile
from sqlalchemy.orm import Session

from ..database import get_db
from ..errors import ApiError
from ..models import User
from ..security.csrf import require_csrf
from ..security.sessions import require_admin
from ..services.imports import confirm_import, preview_import

router = APIRouter(prefix="/api/admin/imports")
MAX_IMPORT_BYTES = 10 * 1024 * 1024


async def _read_import(file: UploadFile) -> bytes:
    content = await file.read(MAX_IMPORT_BYTES + 1)
    if len(content) > MAX_IMPORT_BYTES:
        raise ApiError("import_too_large", "应急文件不能超过 10 MiB", 413)
    if not content:
        raise ApiError("invalid_import", "应急文件为空", 422)
    return content


@router.post("/preview")
async def preview(
    file: Annotated[UploadFile, File()],
    _csrf: Annotated[None, Depends(require_csrf)],
    _admin: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    return preview_import(db, await _read_import(file))


@router.post("/confirm", status_code=201)
async def confirm(
    file: Annotated[UploadFile, File()],
    sha256: Annotated[str, Form(min_length=64, max_length=64)],
    _csrf: Annotated[None, Depends(require_csrf)],
    admin: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
) -> dict[str, object]:
    return confirm_import(
        db,
        content=await _read_import(file),
        expected_sha256=sha256,
        actor=admin,
    )
