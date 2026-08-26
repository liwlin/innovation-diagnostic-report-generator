from __future__ import annotations

import hashlib
from datetime import date, time
from pathlib import Path

import pytest


def test_generation_path_is_human_readable_and_inside_root(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    path = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="批次1",
        student_name="张/三",
        generated_at=time(19, 32, 5),
    )

    assert path.relative_to(tmp_path).as_posix() == "2026年/08月/2026-08-25_批次1/张三/19-32-05"
    assert path.is_dir()


def test_duplicate_generation_second_gets_human_suffix(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    arguments = {
        "event_date": date(2026, 8, 25),
        "batch_name": "批次1",
        "student_name": "张三",
        "generated_at": time(19, 32, 5),
    }

    first = storage.resolve_generation_dir(**arguments)
    second = storage.resolve_generation_dir(**arguments)

    assert first.name == "19-32-05"
    assert second.name == "19-32-05-2"


def test_sanitizer_blocks_dot_components_and_windows_reserved_names(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    path = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="..",
        student_name="CON",
        generated_at=time(1, 2, 3),
    )

    relative = path.relative_to(tmp_path).parts
    assert ".." not in relative
    assert "CON" not in relative


def test_atomic_write_returns_hash_and_leaves_no_partial(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    directory = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="批次1",
        student_name="张三",
        generated_at=time(1, 2, 3),
    )
    content = b"verified-report-content"

    stored = storage.write_atomic(directory, "报告.pdf", content)

    assert stored.path.read_bytes() == content
    assert stored.sha256 == hashlib.sha256(content).hexdigest()
    assert stored.size == len(content)
    assert list(directory.glob("*.partial-*")) == []


def test_validator_failure_leaves_no_final_or_partial_file(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    directory = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="批次1",
        student_name="张三",
        generated_at=time(1, 2, 3),
    )

    def reject(_path: Path) -> None:
        raise ValueError("invalid report")

    with pytest.raises(ValueError, match="invalid report"):
        storage.write_atomic(directory, "报告.pdf", b"broken", validator=reject)

    assert list(directory.iterdir()) == []


def test_atomic_write_refuses_to_overwrite_existing_file(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    directory = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="批次1",
        student_name="张三",
        generated_at=time(1, 2, 3),
    )
    storage.write_atomic(directory, "报告.pdf", b"first")

    with pytest.raises(FileExistsError):
        storage.write_atomic(directory, "报告.pdf", b"second")

    assert (directory / "报告.pdf").read_bytes() == b"first"


def test_delete_refuses_path_outside_report_root(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage, UnsafeReportPath

    report_root = tmp_path / "reports"
    report_root.mkdir()
    company_file = tmp_path / "company" / "资料.pdf"
    company_file.parent.mkdir()
    company_file.write_bytes(b"must-not-change")
    storage = ReportStorage(report_root)

    with pytest.raises(UnsafeReportPath):
        storage.delete_generation_files([company_file])

    assert company_file.read_bytes() == b"must-not-change"


def test_quarantine_restore_returns_files_to_exact_original_paths(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    directory = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="批次1",
        student_name="张三",
        generated_at=time(1, 2, 3),
    )
    first = storage.write_atomic(directory, "报告.pdf", b"first").path
    second = storage.write_atomic(directory, "报告.png", b"second").path

    staged = storage.stage_pending_delete([first, second])

    assert not first.exists()
    assert not second.exists()
    assert all(item.quarantine_path.is_file() for item in staged)

    storage.restore_pending_delete(staged)

    assert first.read_bytes() == b"first"
    assert second.read_bytes() == b"second"
    assert not any((tmp_path / ".pending-delete").rglob("*.*"))


def test_quarantine_finalize_unlinks_only_staged_project_files(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    directory = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="批次1",
        student_name="张三",
        generated_at=time(1, 2, 3),
    )
    report = storage.write_atomic(directory, "报告.pdf", b"final").path

    staged = storage.stage_pending_delete([report])
    storage.finalize_pending_delete(staged)

    assert not report.exists()
    assert not staged[0].quarantine_path.exists()


def test_quarantine_refuses_symlinked_report_file(tmp_path: Path):
    from makerseed_app.reports.storage import ReportStorage, UnsafeReportPath

    storage = ReportStorage(tmp_path)
    target = tmp_path / "outside.txt"
    target.write_bytes(b"outside")
    link = tmp_path / "report-link.pdf"
    link.symlink_to(target)

    with pytest.raises(UnsafeReportPath):
        storage.stage_pending_delete([link])

    assert target.read_bytes() == b"outside"
