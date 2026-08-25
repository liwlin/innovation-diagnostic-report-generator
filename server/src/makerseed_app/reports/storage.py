from __future__ import annotations

import hashlib
import os
import re
import uuid
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import date, time
from pathlib import Path

INVALID_COMPONENT = re.compile(r'[\\/:*?"<>|\x00-\x1f]')
WHITESPACE = re.compile(r"\s+")
WINDOWS_RESERVED_NAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{index}" for index in range(1, 10)),
    *(f"LPT{index}" for index in range(1, 10)),
}


class UnsafeReportPath(ValueError):
    pass


@dataclass(frozen=True)
class StoredFile:
    path: Path
    sha256: str
    size: int


def sanitize_component(value: str, *, fallback: str = "未命名", max_length: int = 100) -> str:
    sanitized = INVALID_COMPONENT.sub("", value)
    sanitized = WHITESPACE.sub(" ", sanitized).strip(" .")
    if sanitized.upper() in WINDOWS_RESERVED_NAMES:
        sanitized = f"_{sanitized}"
    sanitized = sanitized[:max_length].rstrip(" .")
    if sanitized in {"", ".", ".."}:
        return fallback
    return sanitized


class ReportStorage:
    def __init__(self, root: Path) -> None:
        if not root.is_dir():
            raise UnsafeReportPath("report root must be an existing directory")
        if root.is_symlink():
            raise UnsafeReportPath("report root must not be a symbolic link")
        self.root = root.resolve(strict=True)

    def _assert_inside(self, candidate: Path) -> Path:
        resolved = candidate.resolve(strict=False)
        if not resolved.is_relative_to(self.root):
            raise UnsafeReportPath("path is outside the report root")
        return resolved

    def resolve_generation_dir(
        self,
        *,
        event_date: date,
        batch_name: str,
        student_name: str,
        generated_at: time,
    ) -> Path:
        year = f"{event_date.year}年"
        month = f"{event_date.month:02d}月"
        batch = f"{event_date.isoformat()}_{sanitize_component(batch_name, fallback='未命名批次')}"
        student = sanitize_component(student_name, fallback="未命名学生")
        parent = self.root / year / month / batch / student
        self._assert_inside(parent)
        parent.mkdir(parents=True, exist_ok=True)
        if not parent.resolve(strict=True).is_relative_to(self.root):
            raise UnsafeReportPath("generation parent resolved outside the report root")

        base_name = generated_at.strftime("%H-%M-%S")
        for sequence in range(1, 10_000):
            name = base_name if sequence == 1 else f"{base_name}-{sequence}"
            candidate = parent / name
            self._assert_inside(candidate)
            try:
                candidate.mkdir(mode=0o700)
            except FileExistsError:
                continue
            return candidate
        raise FileExistsError("too many generation directories share the same timestamp")

    def write_atomic(
        self,
        directory: Path,
        filename: str,
        content: bytes,
        *,
        validator: Callable[[Path], None] | None = None,
    ) -> StoredFile:
        actual_directory = self._assert_inside(directory)
        if not actual_directory.is_dir():
            raise UnsafeReportPath("generation directory does not exist")
        if Path(filename).name != filename or filename in {"", ".", ".."}:
            raise UnsafeReportPath("filename is not a safe leaf name")
        final_path = self._assert_inside(actual_directory / filename)
        if final_path.exists():
            raise FileExistsError(final_path)
        partial_path = actual_directory / f".{filename}.partial-{uuid.uuid4().hex}"
        self._assert_inside(partial_path)
        try:
            with partial_path.open("xb") as handle:
                os.chmod(partial_path, 0o600)
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            if validator is not None:
                validator(partial_path)
            os.link(partial_path, final_path)
            partial_path.unlink()
        except Exception:
            partial_path.unlink(missing_ok=True)
            raise
        return StoredFile(
            path=final_path,
            sha256=hashlib.sha256(content).hexdigest(),
            size=len(content),
        )

    def delete_generation_files(self, paths: Iterable[Path]) -> None:
        validated: list[Path] = []
        for path in paths:
            candidate = self._assert_inside(path)
            if candidate.exists() and not candidate.is_file():
                raise UnsafeReportPath("only report files can be deleted")
            validated.append(candidate)
        for candidate in validated:
            candidate.unlink(missing_ok=True)

    def resolve_existing_file(self, relative_path: str) -> Path:
        requested = Path(relative_path)
        if requested.is_absolute():
            raise UnsafeReportPath("artifact path must be relative")
        candidate = self._assert_inside(self.root / requested)
        if candidate.is_symlink() or not candidate.is_file():
            raise UnsafeReportPath("artifact is not a regular project file")
        return candidate
