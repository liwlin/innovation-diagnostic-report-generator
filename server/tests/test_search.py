from uuid import UUID

from tests.support import create_batch, create_evaluation


def test_partial_chinese_name_and_grade_filters(authenticated_client_factory):
    teacher = authenticated_client_factory()
    batch = create_batch(teacher)
    create_evaluation(teacher, batch=batch, name="张三", grade="三年级")
    create_evaluation(teacher, batch=batch, name="李四", grade="四年级")

    response = teacher.client.get("/api/evaluations", params={"q": "张", "grade": "三年级"})

    assert response.status_code == 200
    assert [row["student_name"] for row in response.json()["items"]] == ["张三"]


def test_cursor_pagination_has_no_duplicates(authenticated_client_factory):
    teacher = authenticated_client_factory()
    batch = create_batch(teacher)
    for name in ("学生甲", "学生乙", "学生丙"):
        create_evaluation(teacher, batch=batch, name=name)

    first = teacher.client.get("/api/evaluations", params={"limit": 2}).json()
    second = teacher.client.get(
        "/api/evaluations", params={"limit": 2, "cursor": first["next_cursor"]}
    ).json()

    first_ids = {row["evaluation_id"] for row in first["items"]}
    second_ids = {row["evaluation_id"] for row in second["items"]}
    assert len(first["items"]) == 2
    assert len(second["items"]) == 1
    assert first_ids.isdisjoint(second_ids)


def test_date_class_and_generation_status_filters(authenticated_client_factory, db_session):
    from makerseed_app.models import GenerationRecord

    teacher = authenticated_client_factory()
    august_batch = create_batch(teacher, name="八月批次", event_date="2026-08-25")
    july_batch = create_batch(teacher, name="七月批次", event_date="2026-07-01")
    completed = create_evaluation(
        teacher,
        batch=august_batch,
        name="完成同学",
        recommended_class="Python 研习社",
    )
    create_evaluation(
        teacher,
        batch=july_batch,
        name="未生成同学",
        recommended_class="头脑风暴1.0 V1",
    )
    db_session.add(
        GenerationRecord(
            evaluation_id=UUID(completed["evaluation_id"]),
            created_by_id=teacher.user.id,
            status="completed",
            input_snapshot={},
            renderer_version="test",
            artifact_manifest={},
        )
    )
    db_session.commit()

    response = teacher.client.get(
        "/api/evaluations",
        params={
            "date_from": "2026-08-01",
            "recommended_class": "Python 研习社",
            "generation_status": "completed",
        },
    )

    assert response.status_code == 200
    assert [item["student_name"] for item in response.json()["items"]] == ["完成同学"]
    assert response.json()["items"][0]["generation_status"] == "completed"


def test_invalid_cursor_returns_stable_400(authenticated_client_factory):
    teacher = authenticated_client_factory()

    response = teacher.client.get("/api/evaluations", params={"cursor": "%%%not-a-cursor%%%"})

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_cursor"
