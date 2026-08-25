from __future__ import annotations

import io
import math
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from PIL import Image, ImageDraw
from reportlab.lib.colors import Color, HexColor
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfgen import canvas

from ..domain.report_filename import report_filename
from .fonts import load_pillow_font, register_pdf_font, require_font
from .layout import ChartSpec, ReportLayout, ReportSnapshot, build_report_layout
from .storage import ReportStorage

BLUE = "#0F3ED2"
TEXT = "#111827"
MUTED = "#6B7280"
LINE = "#D3D9E5"
PNG_SIZE = (1747, 2471)


@dataclass(frozen=True)
class RenderAssets:
    font_path: Path
    logo_mark_path: Path
    logo_lockup_path: Path

    def validate(self) -> None:
        require_font(self.font_path)
        for path in (self.logo_mark_path, self.logo_lockup_path):
            if not path.is_file():
                raise ValueError(f"required report asset is unavailable: {path.name}")


@dataclass(frozen=True)
class ReportArtifact:
    variant: Literal["with", "without"]
    format: Literal["pdf", "png"]
    path: Path
    relative_path: str
    sha256: str
    size: int
    mime: str


def _wrap_by_width(text: str, measure, max_width: float) -> list[str]:
    lines: list[str] = []
    current = ""
    for character in text:
        if character == "\n":
            lines.append(current)
            current = ""
            continue
        candidate = current + character
        if current and measure(candidate) > max_width:
            lines.append(current)
            current = character
        else:
            current = candidate
    if current or not lines:
        lines.append(current)
    return lines


def _draw_pdf_chart(page: canvas.Canvas, chart: ChartSpec, font_name: str, y_top: float) -> float:
    left = 48.0
    width = 499.0
    height = 96.0
    page.setFont(font_name, 7.5)
    if chart.chart_type == "radar":
        center_x, center_y, radius = 180.0, y_top - 48.0, 38.0
        points = []
        for index, score in enumerate(chart.scores):
            angle = math.radians(-90 + index * 72)
            points.append(
                (
                    center_x + radius * score / 5 * math.cos(angle),
                    center_y + radius * score / 5 * math.sin(angle),
                )
            )
        page.setStrokeColor(HexColor(LINE))
        for ring in range(1, 6):
            ring_points = []
            for index in range(5):
                angle = math.radians(-90 + index * 72)
                ring_points.append(
                    (
                        center_x + radius * ring / 5 * math.cos(angle),
                        center_y + radius * ring / 5 * math.sin(angle),
                    )
                )
            path = page.beginPath()
            path.moveTo(*ring_points[0])
            for point in ring_points[1:]:
                path.lineTo(*point)
            path.close()
            page.drawPath(path, stroke=1, fill=0)
        data_path = page.beginPath()
        data_path.moveTo(*points[0])
        for point in points[1:]:
            data_path.lineTo(*point)
        data_path.close()
        page.setStrokeColor(HexColor(BLUE))
        page.setFillColor(Color(0.06, 0.24, 0.82, alpha=0.15))
        page.drawPath(data_path, stroke=1, fill=1)
        for index, label in enumerate(chart.labels):
            page.setFillColor(HexColor(TEXT))
            page.drawString(240, y_top - 17 - index * 16, f"{label}  {chart.scores[index]}/5")
    elif chart.chart_type == "bar":
        for index, label in enumerate(chart.labels):
            y = y_top - 15 - index * 16
            page.setFillColor(HexColor(TEXT))
            page.drawString(left, y, label)
            page.setFillColor(HexColor("#E5E7EB"))
            page.roundRect(left + 75, y - 2, width - 130, 7, 3, fill=1, stroke=0)
            page.setFillColor(HexColor(BLUE))
            page.roundRect(
                left + 75, y - 2, (width - 130) * chart.scores[index] / 5, 7, 3, fill=1, stroke=0
            )
            page.drawRightString(left + width, y, f"{chart.scores[index]}/5")
    else:
        for index, label in enumerate(chart.labels):
            y = y_top - 15 - index * 16
            page.setFillColor(HexColor(TEXT))
            page.drawString(left, y, label)
            for dot in range(1, 6):
                page.setFillColor(HexColor(BLUE if dot <= chart.scores[index] else "#E5E7EB"))
                page.circle(left + 125 + dot * 32, y + 2, 4, fill=1, stroke=0)
            page.drawRightString(left + width, y, f"{chart.scores[index]}/5")
    return y_top - height


def _render_pdf(layout: ReportLayout, assets: RenderAssets) -> bytes:
    buffer = io.BytesIO()
    font_name = register_pdf_font(assets.font_path)
    page = canvas.Canvas(buffer, pagesize=A4, pageCompression=1)
    page.setTitle(layout.title)
    page.setAuthor("MakerSeed")
    page.drawImage(
        str(assets.logo_lockup_path),
        42,
        792,
        width=124,
        height=27,
        preserveAspectRatio=True,
        mask="auto",
    )
    page.setFillColor(HexColor(BLUE))
    page.setFont(font_name, 18)
    page.drawString(42, 758, layout.title)
    page.setFillColor(HexColor(MUTED))
    page.setFont(font_name, 8)
    page.drawString(42, 743, layout.subtitle)

    page.setFillColor(HexColor(TEXT))
    page.setFont(font_name, 8.5)
    for index, item in enumerate(layout.metadata):
        column = index % 3
        row = index // 3
        page.drawString(42 + column * 178, 718 - row * 18, item)

    page.setFillColor(HexColor(BLUE))
    page.setFont(font_name, 9.5)
    page.drawString(42, 674, "体验模块")
    page.setFillColor(HexColor(TEXT))
    page.setFont(font_name, 8)
    page.drawString(42, 658, " · ".join(layout.modules) if layout.modules else "暂无记录")

    page.setFillColor(HexColor(BLUE))
    page.setFont(font_name, 9.5)
    page.drawString(42, 633, "能力画像")
    y = _draw_pdf_chart(page, layout.chart, font_name, 622)

    for section in layout.sections:
        page.setStrokeColor(HexColor(LINE))
        page.line(42, y, 553, y)
        y -= 15
        page.setFillColor(HexColor(BLUE))
        page.setFont(font_name, 9.5)
        page.drawString(42, y, section.title)
        y -= 13
        page.setFillColor(HexColor(TEXT))
        page.setFont(font_name, 7.5)
        for paragraph in section.paragraphs:
            lines = _wrap_by_width(
                paragraph,
                lambda value: pdfmetrics.stringWidth(value, font_name, 7.5),
                500,
            )
            for line in lines[:4]:
                page.drawString(48, y, line)
                y -= 10
            y -= 2
        y -= 4

    if layout.internal:
        page.saveState()
        page.setFillColor(Color(0.75, 0.1, 0.1, alpha=0.18))
        page.setFont(font_name, 30)
        page.translate(300, 400)
        page.rotate(35)
        page.drawCentredString(0, 0, "仅限内部使用")
        page.restoreState()

    page.setFillColor(HexColor(MUTED))
    page.setFont(font_name, 6.5)
    page.drawString(42, 20, "MakerSeed 科创体验诊断报告")
    if layout.internal:
        page.drawRightString(553, 20, "仅限内部使用")
    page.showPage()
    page.save()
    return buffer.getvalue()


def _pillow_wrap(draw: ImageDraw.ImageDraw, text: str, font, max_width: int) -> list[str]:
    return _wrap_by_width(text, lambda value: draw.textlength(value, font=font), max_width)


def _draw_png_chart(draw: ImageDraw.ImageDraw, chart: ChartSpec, font, top: int) -> int:
    left, width, height = 95, 1557, 260
    if chart.chart_type == "radar":
        center_x, center_y, radius = 450, top + 130, 100
        for ring in range(1, 6):
            points = []
            for index in range(5):
                angle = math.radians(-90 + index * 72)
                points.append(
                    (
                        center_x + radius * ring / 5 * math.cos(angle),
                        center_y + radius * ring / 5 * math.sin(angle),
                    )
                )
            draw.polygon(points, outline=LINE)
        data = []
        for index, score in enumerate(chart.scores):
            angle = math.radians(-90 + index * 72)
            data.append(
                (
                    center_x + radius * score / 5 * math.cos(angle),
                    center_y + radius * score / 5 * math.sin(angle),
                )
            )
        draw.polygon(data, outline=BLUE, fill="#DDE6FF")
        for index, label in enumerate(chart.labels):
            draw.text(
                (680, top + 20 + index * 43),
                f"{label}  {chart.scores[index]}/5",
                font=font,
                fill=TEXT,
            )
    elif chart.chart_type == "bar":
        for index, label in enumerate(chart.labels):
            y = top + 18 + index * 46
            draw.text((left, y), label, font=font, fill=TEXT)
            draw.rounded_rectangle(
                (left + 250, y + 3, left + width - 100, y + 24), radius=10, fill="#E5E7EB"
            )
            filled = (width - 350) * chart.scores[index] / 5
            draw.rounded_rectangle(
                (left + 250, y + 3, left + 250 + filled, y + 24), radius=10, fill=BLUE
            )
            draw.text((left + width - 80, y), f"{chart.scores[index]}/5", font=font, fill=TEXT)
    else:
        for index, label in enumerate(chart.labels):
            y = top + 18 + index * 46
            draw.text((left, y), label, font=font, fill=TEXT)
            for dot in range(1, 6):
                x = left + 300 + dot * 90
                draw.ellipse(
                    (x, y, x + 24, y + 24), fill=BLUE if dot <= chart.scores[index] else "#E5E7EB"
                )
            draw.text((left + width - 80, y), f"{chart.scores[index]}/5", font=font, fill=TEXT)
    return top + height


def _render_png(layout: ReportLayout, assets: RenderAssets) -> bytes:
    image = Image.new("RGB", PNG_SIZE, "white")
    draw = ImageDraw.Draw(image, "RGBA")
    title_font = load_pillow_font(assets.font_path, 48)
    section_font = load_pillow_font(assets.font_path, 27)
    body_font = load_pillow_font(assets.font_path, 22)
    small_font = load_pillow_font(assets.font_path, 18)

    with Image.open(assets.logo_lockup_path) as logo_source:
        logo_image = logo_source.convert("RGBA")
        logo_image.thumbnail((360, 80), Image.Resampling.LANCZOS)
        image.paste(logo_image, (90, 70), logo_image)
    draw.text((90, 165), layout.title, font=title_font, fill=BLUE)
    draw.text((90, 228), layout.subtitle, font=small_font, fill=MUTED)
    for index, item in enumerate(layout.metadata):
        draw.text((90 + index % 3 * 540, 285 + index // 3 * 48), item, font=body_font, fill=TEXT)

    y = 400
    draw.text((90, y), "体验模块", font=section_font, fill=BLUE)
    y += 45
    draw.text(
        (100, y),
        " · ".join(layout.modules) if layout.modules else "暂无记录",
        font=body_font,
        fill=TEXT,
    )
    y += 62
    draw.text((90, y), "能力画像", font=section_font, fill=BLUE)
    y = _draw_png_chart(draw, layout.chart, body_font, y + 45)

    for section in layout.sections:
        draw.line((90, y, 1657, y), fill=LINE, width=2)
        y += 20
        draw.text((90, y), section.title, font=section_font, fill=BLUE)
        y += 43
        for paragraph in section.paragraphs:
            lines = _pillow_wrap(draw, paragraph, body_font, 1510)
            for line in lines[:4]:
                draw.text((105, y), line, font=body_font, fill=TEXT)
                y += 31
            y += 8
        y += 12

    if layout.internal:
        watermark = Image.new("RGBA", PNG_SIZE, (255, 255, 255, 0))
        watermark_draw = ImageDraw.Draw(watermark)
        watermark_font = load_pillow_font(assets.font_path, 100)
        watermark_draw.text(
            (460, 1100), "仅限内部使用", font=watermark_font, fill=(180, 20, 20, 38)
        )
        watermark = watermark.rotate(30, expand=False, center=(873, 1235))
        image = Image.alpha_composite(image.convert("RGBA"), watermark).convert("RGB")
        draw = ImageDraw.Draw(image)
    draw.text((90, 2415), "MakerSeed 科创体验诊断报告", font=small_font, fill=MUTED)
    if layout.internal:
        draw.text((1450, 2415), "仅限内部使用", font=small_font, fill="#991B1B")
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def _validate_pdf(path: Path) -> None:
    if not path.read_bytes().startswith(b"%PDF-"):
        raise ValueError("rendered PDF signature is invalid")


def _validate_png(path: Path) -> None:
    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as image:
        if image.size != PNG_SIZE or image.format != "PNG":
            raise ValueError("rendered PNG dimensions or format are invalid")


def render_report_set(
    snapshot: ReportSnapshot,
    storage: ReportStorage,
    output_dir: Path,
    assets: RenderAssets,
) -> list[ReportArtifact]:
    assets.validate()
    artifacts: list[ReportArtifact] = []
    student_name = str(snapshot.student.get("name") or "")
    date_label = str(snapshot.batch.get("date_label") or "")
    variants: tuple[tuple[Literal["with", "without"], bool], ...] = (
        ("without", False),
        ("with", True),
    )
    for variant, internal in variants:
        layout = build_report_layout(snapshot, internal=internal)
        filename = report_filename(student_name, date_label, variant, snapshot.filename_pattern)
        outputs: tuple[
            tuple[
                Literal["pdf", "png"],
                str,
                bytes,
                Callable[[Path], None],
            ],
            ...,
        ] = (
            ("pdf", "application/pdf", _render_pdf(layout, assets), _validate_pdf),
            ("png", "image/png", _render_png(layout, assets), _validate_png),
        )
        for output_format, mime, content, validator in outputs:
            stored = storage.write_atomic(
                output_dir,
                f"{filename}.{output_format}",
                content,
                validator=validator,
            )
            artifacts.append(
                ReportArtifact(
                    variant=variant,
                    format=output_format,
                    path=stored.path,
                    relative_path=stored.path.relative_to(storage.root).as_posix(),
                    sha256=stored.sha256,
                    size=stored.size,
                    mime=mime,
                )
            )
    return artifacts
