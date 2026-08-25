from __future__ import annotations

import hashlib
from pathlib import Path

from PIL import ImageFont
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont


class ReportFontError(ValueError):
    pass


def require_font(font_path: Path) -> Path:
    if not font_path.is_file():
        raise ReportFontError(f"configured CJK font is unavailable: {font_path.name}")
    return font_path


def register_pdf_font(font_path: Path) -> str:
    actual_path = require_font(font_path)
    digest = hashlib.sha256(str(actual_path.resolve()).encode()).hexdigest()[:12]
    font_name = f"MakerSeedCJK-{digest}"
    if font_name not in pdfmetrics.getRegisteredFontNames():
        pdfmetrics.registerFont(TTFont(font_name, str(actual_path)))
    return font_name


def load_pillow_font(font_path: Path, size: int) -> ImageFont.FreeTypeFont:
    actual_path = require_font(font_path)
    return ImageFont.truetype(str(actual_path), size=size)
