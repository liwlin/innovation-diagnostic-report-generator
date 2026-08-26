from __future__ import annotations

import json
from datetime import date, time
from pathlib import Path

import pytest
from PIL import Image
from pypdf import PdfReader

from tests.support import cjk_font_path

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "report-snapshot.json"
PROJECT_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def snapshot_mapping() -> dict:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


@pytest.fixture
def render_assets():
    from makerseed_app.reports.renderer import RenderAssets

    return RenderAssets(
        font_path=cjk_font_path(),
        logo_mark_path=PROJECT_ROOT / "assets" / "logo-mark.png",
        logo_lockup_path=PROJECT_ROOT / "assets" / "logo-lockup.png",
    )


def _render(tmp_path: Path, snapshot_mapping: dict, render_assets):
    from makerseed_app.reports.layout import ReportSnapshot
    from makerseed_app.reports.renderer import render_report_set
    from makerseed_app.reports.storage import ReportStorage

    storage = ReportStorage(tmp_path)
    output_dir = storage.resolve_generation_dir(
        event_date=date(2026, 8, 25),
        batch_name="批次1",
        student_name="张三",
        generated_at=time(19, 32, 5),
    )
    snapshot = ReportSnapshot.from_mapping(snapshot_mapping)
    return render_report_set(snapshot, storage, output_dir, render_assets)


def test_renderer_creates_four_distinct_valid_artifacts(
    tmp_path: Path, snapshot_mapping: dict, render_assets
):
    artifacts = _render(tmp_path, snapshot_mapping, render_assets)

    assert {(artifact.variant, artifact.format) for artifact in artifacts} == {
        ("without", "pdf"),
        ("without", "png"),
        ("with", "pdf"),
        ("with", "png"),
    }
    assert all(artifact.size > 3_000 and len(artifact.sha256) == 64 for artifact in artifacts)
    assert len({artifact.sha256 for artifact in artifacts}) == 4
    assert {artifact.path.name for artifact in artifacts} == {
        "张三_8月25日_科创体验报告_无内联.pdf",
        "张三_8月25日_科创体验报告_无内联.png",
        "张三_8月25日_科创体验报告_含内联.pdf",
        "张三_8月25日_科创体验报告_含内联.png",
    }


def test_pdf_is_single_a4_page_and_parent_excludes_internal_text(
    tmp_path: Path, snapshot_mapping: dict, render_assets
):
    artifacts = _render(tmp_path, snapshot_mapping, render_assets)
    parent_pdf = next(a for a in artifacts if a.variant == "without" and a.format == "pdf")
    internal_pdf = next(a for a in artifacts if a.variant == "with" and a.format == "pdf")

    parent_reader = PdfReader(parent_pdf.path)
    internal_reader = PdfReader(internal_pdf.path)
    assert len(parent_reader.pages) == 1
    assert float(parent_reader.pages[0].mediabox.width) == pytest.approx(595.28, abs=1)
    assert float(parent_reader.pages[0].mediabox.height) == pytest.approx(841.89, abs=1)
    parent_text = parent_reader.pages[0].extract_text()
    internal_text = internal_reader.pages[0].extract_text()
    assert "课堂具体表现" in parent_text
    assert "内部备注" not in parent_text
    assert "仅限内部使用" not in parent_text
    assert "内部备注：适合项目制小组" in internal_text
    assert "仅限内部使用" in internal_text


def test_png_dimensions_match_legacy_export(tmp_path: Path, snapshot_mapping: dict, render_assets):
    artifacts = _render(tmp_path, snapshot_mapping, render_assets)

    for artifact in (item for item in artifacts if item.format == "png"):
        with Image.open(artifact.path) as image:
            assert image.size == (1747, 2471)
            assert image.format == "PNG"


@pytest.mark.parametrize("chart_type", ["radar", "bar", "dot"])
def test_all_chart_types_build_non_empty_layout(snapshot_mapping: dict, chart_type: str):
    from makerseed_app.reports.layout import ReportSnapshot, build_report_layout

    snapshot_mapping["payload"]["chart"] = chart_type
    layout = build_report_layout(ReportSnapshot.from_mapping(snapshot_mapping), internal=False)

    assert layout.chart.chart_type == chart_type
    assert layout.chart.scores == (4, 3, 5, 4, 3)
    assert layout.sections


def test_parent_layout_contains_no_internal_fields(snapshot_mapping: dict):
    from makerseed_app.reports.layout import ReportSnapshot, build_report_layout

    snapshot = ReportSnapshot.from_mapping(snapshot_mapping)
    parent = build_report_layout(snapshot, internal=False)
    internal = build_report_layout(snapshot, internal=True)

    assert all(section.title != "内部跟进" for section in parent.sections)
    assert any(section.title == "内部跟进" for section in internal.sections)


def test_test_font_resolver_rejects_incompatible_noto_cff_path(monkeypatch, tmp_path: Path):
    font_path = tmp_path / "NotoSansCJK-Regular.ttc"
    font_path.write_bytes(b"fake font")
    monkeypatch.setenv("MKSEED_TEST_CJK_FONT", str(font_path))

    with pytest.raises(AssertionError, match="Noto CJK CFF"):
        cjk_font_path()


def test_test_font_resolver_accepts_wqy_override(monkeypatch, tmp_path: Path):
    font_path = tmp_path / "wqy-zenhei.ttc"
    font_path.write_bytes(b"fake font")
    monkeypatch.setenv("MKSEED_TEST_CJK_FONT", str(font_path))

    assert cjk_font_path() == font_path
