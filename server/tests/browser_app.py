from __future__ import annotations

import os
from datetime import date
from pathlib import Path

from sqlalchemy import select

from makerseed_app.config import Settings
from makerseed_app.main import create_app
from makerseed_app.models import Base, Batch, Evaluation, Student, User
from makerseed_app.security.passwords import hash_password
from tests.support import cjk_font_path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
STATE_ROOT = Path(os.environ["MKSEED_BROWSER_STATE_ROOT"]).resolve()
STATE_ROOT.mkdir(parents=True, exist_ok=True)
REPORT_ROOT = STATE_ROOT / "reports"
REPORT_ROOT.mkdir(exist_ok=True)

settings = Settings(
    environment="test",
    app_version="browser-test",
    database_url=f"sqlite+pysqlite:///{(STATE_ROOT / 'browser.sqlite3').as_posix()}",
    session_secret="browser-test-session-secret-not-for-production",
    bootstrap_secret="browser-test-bootstrap-secret-not-for-production",
    secure_cookies=False,
    generation_worker_enabled=True,
    generation_poll_seconds=0.1,
    report_root=REPORT_ROOT,
    report_font_path=cjk_font_path(),
    logo_mark_path=PROJECT_ROOT / "assets" / "logo-mark.png",
    logo_lockup_path=PROJECT_ROOT / "assets" / "logo-lockup.png",
    filename_pattern="{name}_{date}_科创体验报告",
    promo_text="浏览器测试课程说明",
    static_root=PROJECT_ROOT,
    nas_web_root=PROJECT_ROOT / "nas-web",
)
app = create_app(settings)
Base.metadata.create_all(app.state.engine)


def _payload(index: int) -> dict:
    return {
        "schema_version": 1,
        "mods": ["乐高搭建", "Mind+图形化编程"],
        "customMods": [],
        "chart": "radar",
        "rates": [4, 3, 5, 4, 3],
        "skills": [
            {"m": "乐高搭建", "p": "能独立完成齿轮结构", "r": 4},
            {"m": "Mind+图形化编程", "p": "能定位循环逻辑错误", "r": 5},
            {"m": "", "p": "", "r": 0},
        ],
        "obs1": f"测试记录 {index}：学生发现结构转向问题后主动调整齿轮组合，并说明修改原因。",
        "obs2": "下一步记录不同方案的优缺点，并尝试程序控制。",
        "dir": 0,
        "reason": "动手实践和创意想法表现突出。",
        "classIndex": "0",
        "recommended_class": "头脑风暴1.0 V1",
        "dirCustom": {"name": "", "desc": ""},
        "attendp": "是",
        "talk": "已完成",
        "intent": "高",
        "why": "喜欢机器人",
        "ref": "家长希望加强表达",
        "follow": "三天内联系",
        "note": "浏览器测试内部备注",
        "generated": False,
    }


def seed() -> None:
    with app.state.session_factory() as db:
        if db.scalar(select(User.id).limit(1)) is not None:
            return
        admin = User(
            username="browser-admin",
            display_name="测试管理员",
            role="admin",
            password_hash=hash_password("Browser admin password 2026"),
        )
        teacher_a = User(
            username="browser-teacher-a",
            display_name="测试老师甲",
            role="teacher",
            password_hash=hash_password("Browser teacher A password 2026"),
        )
        teacher_b = User(
            username="browser-teacher-b",
            display_name="测试老师乙",
            role="teacher",
            password_hash=hash_password("Browser teacher B password 2026"),
        )
        db.add_all([admin, teacher_a, teacher_b])
        db.flush()
        names = ("张子涵", "王浩宇", "李思雨", "陈俊熙", "刘雨桐", "赵天宇")
        for index, name in enumerate(names):
            batch = Batch(
                display_name="2026暑期批次A" if index < 4 else "2026暑期批次B",
                event_date=date(2026, 8, 26),
                date_label="8月26日",
                teacher_label="测试老师甲",
                fill_date=date(2026, 8, 26),
                created_by_id=teacher_a.id,
            )
            db.add(batch)
            db.flush()
            student = Student(
                batch_id=batch.id,
                name=name,
                grade="三年级" if index % 2 == 0 else "四年级",
                slot="上午场",
            )
            db.add(student)
            db.flush()
            db.add(
                Evaluation(
                    student_id=student.id,
                    payload=_payload(index),
                    schema_version=1,
                    recommended_class="头脑风暴1.0 V1",
                    created_by_id=teacher_a.id,
                    updated_by_id=teacher_a.id,
                )
            )
        db.commit()


seed()
