from tests.support import create_evaluation


def test_stale_update_returns_409_and_keeps_newer_data(authenticated_client_factory):
    teacher_a = authenticated_client_factory(username="conflict-a")
    teacher_b = authenticated_client_factory(username="conflict-b")
    created = create_evaluation(teacher_a)
    url = f"/api/evaluations/{created['evaluation_id']}/editor"
    first = teacher_a.client.get(url).json()
    stale = teacher_b.client.get(url).json()

    first["payload"]["note"] = "A 的保存"
    first_response = teacher_a.client.put(
        f"/api/evaluations/{created['evaluation_id']}",
        headers={"X-CSRF-Token": teacher_a.csrf},
        json={
            "version": first["version"],
            "student": first["student"],
            "payload": first["payload"],
        },
    )
    assert first_response.status_code == 200

    stale["payload"]["note"] = "B 的旧版本"
    stale_response = teacher_b.client.put(
        f"/api/evaluations/{created['evaluation_id']}",
        headers={"X-CSRF-Token": teacher_b.csrf},
        json={
            "version": stale["version"],
            "student": stale["student"],
            "payload": stale["payload"],
        },
    )

    assert stale_response.status_code == 409
    assert stale_response.json()["error"] == {
        "code": "version_conflict",
        "message": "记录已被其他老师修改，请重新加载",
        "details": {"current_version": first_response.json()["version"]},
    }
    current = teacher_b.client.get(url).json()
    assert current["payload"]["note"] == "A 的保存"
