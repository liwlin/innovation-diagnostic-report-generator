from __future__ import annotations

import json
from pathlib import Path

import pytest

CASES_PATH = Path(__file__).resolve().parents[2] / "shared" / "report-filename-cases.json"
CASES = json.loads(CASES_PATH.read_text(encoding="utf-8"))


@pytest.mark.parametrize("fixture", CASES, ids=lambda case: case["expected"])
def test_python_filename_matches_shared_fixture(fixture):
    from makerseed_app.domain.report_filename import report_filename

    assert (
        report_filename(
            fixture["name"],
            fixture["date"],
            fixture["variant"],
            fixture["pattern"],
            fixture.get("today_compact"),
        )
        == fixture["expected"]
    )
