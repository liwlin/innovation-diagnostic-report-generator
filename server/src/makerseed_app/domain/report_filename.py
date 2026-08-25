from __future__ import annotations

import re
from datetime import date
from typing import Literal

DEFAULT_PATTERN = "{name}_{date}_科创体验报告"
INVALID_FILENAME_CHARACTERS = re.compile(r'[\\/:*?"<>|]')


def report_filename(
    name: str,
    date_label: str,
    variant: Literal["with", "without"] | None,
    pattern: str,
    today_compact: str | None = None,
) -> str:
    actual_pattern = pattern or DEFAULT_PATTERN
    actual_date = (date_label or "").strip() or today_compact or date.today().strftime("%Y%m%d")
    actual_name = (name or "学员").strip()
    output = actual_pattern.replace("{name}", actual_name).replace("{date}", actual_date)
    if variant == "with":
        output += "_含内联"
    elif variant == "without":
        output += "_无内联"
    output = INVALID_FILENAME_CHARACTERS.sub("", output).strip()
    return output or "科创体验报告"
