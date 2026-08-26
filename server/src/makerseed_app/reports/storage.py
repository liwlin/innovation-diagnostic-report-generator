from __future__ import annotations

import hashlib
import os
import re
import uuid
from collections.abc import Callable, Iterable
from contextlib import suppress
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


@dataclass(frozen=True)
class PendingDeleteFile:
    original_path: Path
    quarantine_path: Path


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
        staged = self.stage_pending_delete(paths)
        self.finalize_pending_delete(staged)

    def stage_pending_delete(self, paths: Iterable[Path]) -> list[PendingDeleteFile]:
        batch_root = self._assert_inside(self.root / ".pending-delete" / uuid.uuid4().hex)
        staged: list[PendingDeleteFile] = []
        try:
            for path in paths:
                if path.is_symlink():
                    raise UnsafeReportPath("report file must not be a symbolic link")
                candidate = self._assert_inside(path)
                if candidate.is_symlink() or not candidate.is_file():
                    raise UnsafeReportPath("only regular report files can be staged for deletion")
                relative = candidate.relative_to(self.root)
                quarantine_path = self._assert_inside(batch_root / relative)
                quarantine_path.parent.mkdir(parents=True, exist_ok=True)
                os.replace(candidate, quarantine_path)
                staged.append(
                    PendingDeleteFile(original_path=candidate, quarantine_path=quarantine_path)
                )
        except Exception:
            self.restore_pending_delete(reversed(staged))
            raise
        return staged

    def restore_pending_delete(self, staged: Iterable[PendingDeleteFile]) -> None:
        restored_roots: set[Path] = set()
        for item in staged:
            original_path = self._assert_inside(item.original_path)
            quarantine_path = self._assert_inside(item.quarantine_path)
            if not quarantine_path.is_file() or quarantine_path.is_symlink():
                raise UnsafeReportPath("pending-delete file is missing or unsafe")
            if original_path.exists():
                raise FileExistsError(original_path)
            original_path.parent.mkdir(parents=True, exist_ok=True)
            os.replace(quarantine_path, original_path)
            restored_roots.add(quarantine_path.parent)
        self._cleanup_empty_pending_dirs(restored_roots)

    def finalize_pending_delete(self, staged: Iterable[PendingDeleteFile]) -> None:
        touched_dirs: set[Path] = set()
        for item in staged:
            quarantine_path = self._assert_inside(item.quarantine_path)
            if quarantine_path.exists():
                if quarantine_path.is_symlink() or not quarantine_path.is_file():
                    raise UnsafeReportPath("pending-delete target is not a regular file")
                quarantine_path.unlink()
            touched_dirs.add(quarantine_path.parent)
        self._cleanup_empty_pending_dirs(touched_dirs)

    def _cleanup_empty_pending_dirs(self, directories: Iterable[Path]) -> None:
        pending_root = self.root / ".pending-delete"
        for directory in sorted(set(directories), key=lambda value: len(value.parts), reverse=True):
            current = self._assert_inside(directory)
            while current != pending_root and current.is_relative_to(pending_root):
                try:
                    current.rmdir()
                except OSError:
                    break
                current = current.parent
        with suppress(OSError):
            pending_root.rmdir()

    def resolve_existing_file(self, relative_path: str) -> Path:
        requested = Path(relative_path)
        if requested.is_absolute():
            raise UnsafeReportPath("artifact path must be relative")
        candidate = self._assert_inside(self.root / requested)
        if candidate.is_symlink() or not candidate.is_file():
            raise UnsafeReportPath("artifact is not a regular project file")
        return candidate
