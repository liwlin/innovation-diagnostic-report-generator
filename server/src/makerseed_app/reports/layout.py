from __future__ import annotations

from collections.abc import Mapping
from copy import deepcopy
from dataclasses import dataclass
from typing import Any, Literal

DIMENSION_LABELS = ("动手实践", "理解表达", "专注投入", "创意想法", "合作习惯")
DIRECTION_LABELS = ("机器人", "编程", "创客造物", "AI / 竞赛")
ChartType = Literal["radar", "bar", "dot"]


@dataclass(frozen=True)
class ReportSnapshot:
    evaluation_id: str
    generation_id: str
    filename_pattern: str
    batch: dict[str, Any]
    student: dict[str, Any]
    payload: dict[str, Any]
    promo_text: str

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> ReportSnapshot:
        return cls(
            evaluation_id=str(value["evaluation_id"]),
            generation_id=str(value["generation_id"]),
            filename_pattern=str(value.get("filename_pattern") or "{name}_{date}_科创体验报告"),
            batch=deepcopy(dict(value["batch"])),
            student=deepcopy(dict(value["student"])),
            payload=deepcopy(dict(value["payload"])),
            promo_text=str(value.get("promo_text") or ""),
        )


@dataclass(frozen=True)
class ChartSpec:
    chart_type: ChartType
    labels: tuple[str, ...]
    scores: tuple[int, ...]


@dataclass(frozen=True)
class ReportSection:
    title: str
    paragraphs: tuple[str, ...]


@dataclass(frozen=True)
class ReportLayout:
    title: str
    subtitle: str
    metadata: tuple[str, ...]
    modules: tuple[str, ...]
    chart: ChartSpec
    sections: tuple[ReportSection, ...]
    internal: bool


def _score_label(score: int) -> str:
    labels = ("—", "正在起步", "稳步提升", "达标", "良好", "突出")
    return labels[score] if 0 <= score <= 5 else "—"


def _direction_text(payload: Mapping[str, Any]) -> str:
    selected = int(payload.get("dir", -1))
    if 0 <= selected < len(DIRECTION_LABELS):
        return DIRECTION_LABELS[selected]
    if selected == 4:
        custom = payload.get("dirCustom") or {}
        return str(custom.get("name") or "自定义方向")
    return "未选择"


def build_report_layout(snapshot: ReportSnapshot, *, internal: bool) -> ReportLayout:
    payload = snapshot.payload
    scores = tuple(int(value) for value in payload.get("rates", [0, 0, 0, 0, 0]))
    chart_type = str(payload.get("chart") or "radar")
    if chart_type not in {"radar", "bar", "dot"}:
        chart_type = "radar"
    modules = tuple(str(value) for value in payload.get("mods", []) if str(value).strip())
    skill_lines = []
    for skill in payload.get("skills", []):
        module = str(skill.get("m") or "—")
        point = str(skill.get("p") or "").strip()
        rating = _score_label(int(skill.get("r") or 0))
        if module != "—" or point:
            skill_lines.append(f"{module}｜{point or '—'}｜{rating}")

    sections = [
        ReportSection("技能亮点", tuple(skill_lines) or ("暂无记录",)),
        ReportSection("课堂具体表现", (str(payload.get("obs1") or "—"),)),
        ReportSection("下一步成长建议", (str(payload.get("obs2") or "—"),)),
        ReportSection(
            "推荐方向与班级",
            (
                f"推荐方向：{_direction_text(payload)}",
                f"推荐班级：{payload.get('recommended_class') or '—'}",
                f"推荐理由：{payload.get('reason') or '—'}",
            ),
        ),
    ]
    if snapshot.promo_text:
        sections.append(ReportSection("课程说明", (snapshot.promo_text,)))
    if internal:
        sections.append(
            ReportSection(
                "内部跟进",
                (
                    f"家长到场：{payload.get('attendp') or '—'}",
                    f"沟通状态：{payload.get('talk') or '—'}",
                    f"意向：{payload.get('intent') or '—'}",
                    f"关注原因：{payload.get('why') or '—'}",
                    f"家长诉求：{payload.get('ref') or '—'}",
                    f"跟进安排：{payload.get('follow') or '—'}",
                    str(payload.get("note") or "—"),
                ),
            )
        )

    metadata = (
        f"学员：{snapshot.student.get('name') or '—'}",
        f"年级：{snapshot.student.get('grade') or '—'}",
        f"体验日期：{snapshot.batch.get('date_label') or '—'}",
        f"场次：{snapshot.student.get('slot') or '—'}",
        f"教师：{snapshot.batch.get('teacher_label') or '—'}",
        f"填写日期：{snapshot.batch.get('fill_date') or '—'}",
    )
    return ReportLayout(
        title="科创体验诊断报告",
        subtitle="MakerSeed · 让每一次体验都有清晰成长路径",
        metadata=metadata,
        modules=modules,
        chart=ChartSpec(chart_type, DIMENSION_LABELS, scores),  # type: ignore[arg-type]
        sections=tuple(sections),
        internal=internal,
    )
