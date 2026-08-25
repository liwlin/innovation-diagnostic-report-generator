from __future__ import annotations

from pathlib import Path
from uuid import UUID

from makerseed_app.models import Evaluation, GenerationRecord
from tests.support import create_evaluation


def _valid_evaluation(identity, **kwargs):
    return create_evaluation(
        identity,
        payload_changes={
            "dir": 0,
            "obs1": "完成了齿轮结构并主动解释转向关系。",
            "obs2": "继续比较不同方案并记录结果。",
            "reason": "动手实践和创意想法表现突出。",
        },
        **kwargs,
    )


def test_teacher_generates_and_downloads_another_teachers_record(app, authenticated_client_factory):
    from makerseed_app.reports.jobs import job_settings_from_app, process_next_generation

    owner = authenticated_client_factory(username="generation-owner")
    teacher = authenticated_client_factory(username="generation-teacher")
    created = _valid_evaluation(owner, name="报告学生")
    evaluation_id = created["evaluation_id"]

    queued = teacher.client.post(
        f"/api/evaluations/{evaluation_id}/generations",
        headers={"X-CSRF-Token": teacher.csrf},
    )

    assert queued.status_code == 202
    assert queued.json()["status"] == "queued"
    with app.state.session_factory() as db:
        assert process_next_generation(db, job_settings_from_app(app.state.settings)) == UUID(
            queued.json()["id"]
        )

    detail = teacher.client.get(f"/api/generations/{queued.json()['id']}")
    assert detail.status_code == 200
    assert detail.json()["status"] == "completed"
    artifacts = detail.json()["artifacts"]
    assert {item["id"] for item in artifacts} == {
        "without-pdf",
        "without-png",
        "with-pdf",
        "with-png",
    }
    download = teacher.client.get(f"/api/generations/{queued.json()['id']}/files/without-pdf")
    assert download.status_code == 200
    assert download.headers["content-type"] == "application/pdf"
    assert download.headers["x-content-type-options"] == "nosniff"
    assert download.headers["cache-control"] == "no-store, private"
    assert "filename*=utf-8''" in download.headers["content-disposition"].lower()
    assert download.content.startswith(b"%PDF-")


def test_incomplete_and_trashed_records_cannot_generate(authenticated_client_factory):
    teacher = authenticated_client_factory()
    incomplete = create_evaluation(teacher)

    not_ready = teacher.client.post(
        f"/api/evaluations/{incomplete['evaluation_id']}/generations",
        headers={"X-CSRF-Token": teacher.csrf},
    )
    assert not_ready.status_code == 422
    assert not_ready.json()["error"]["code"] == "report_not_ready"

    ready = _valid_evaluation(teacher, name="回收站学生")
    teacher.client.post(
        f"/api/evaluations/{ready['evaluation_id']}/trash",
        headers={"X-CSRF-Token": teacher.csrf},
    )
    trashed = teacher.client.post(
        f"/api/evaluations/{ready['evaluation_id']}/generations",
        headers={"X-CSRF-Token": teacher.csrf},
    )
    assert trashed.status_code == 409
    assert trashed.json()["error"]["code"] == "evaluation_trashed"


def test_failed_generation_can_be_requeued(authenticated_client_factory, db_session):
    teacher = authenticated_client_factory()
    created = _valid_evaluation(teacher)
    queued = teacher.client.post(
        f"/api/evaluations/{created['evaluation_id']}/generations",
        headers={"X-CSRF-Token": teacher.csrf},
    ).json()
    job = db_session.get(GenerationRecord, UUID(queued["id"]))
    assert job is not None
    job.status = "failed"
    job.attempts = 3
    job.error_code = "render_failed"
    db_session.commit()

    response = teacher.client.post(
        f"/api/generations/{job.id}/retry",
        headers={"X-CSRF-Token": teacher.csrf},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "queued"
    assert response.json()["attempts"] == 0


def test_unknown_artifact_id_is_not_a_path(authenticated_client_factory, db_session):
    teacher = authenticated_client_factory()
    created = _valid_evaluation(teacher)
    job = GenerationRecord(
        evaluation_id=UUID(created["evaluation_id"]),
        created_by_id=teacher.user.id,
        status="completed",
        input_snapshot={},
        renderer_version="test",
        artifact_manifest={"artifacts": []},
    )
    db_session.add(job)
    db_session.commit()

    response = teacher.client.get(f"/api/generations/{job.id}/files/../../company.txt")

    assert response.status_code in {404, 422}


def test_permanent_delete_fails_closed_for_artifact_outside_report_root(
    app, authenticated_client_factory, db_session, tmp_path: Path
):
    owner = authenticated_client_factory(username="unsafe-owner")
    admin = authenticated_client_factory(username="unsafe-admin", role="admin")
    created = _valid_evaluation(owner, name="路径测试学生")
    outside_file = tmp_path / "company.txt"
    outside_file.write_bytes(b"must-not-change")
    job = GenerationRecord(
        evaluation_id=UUID(created["evaluation_id"]),
        created_by_id=owner.user.id,
        status="completed",
        input_snapshot={},
        renderer_version="test",
        artifact_manifest={
            "artifacts": [
                {
                    "id": "without-pdf",
                    "variant": "without",
                    "format": "pdf",
                    "relative_path": "../company.txt",
                    "sha256": "0" * 64,
                    "size": outside_file.stat().st_size,
                    "mime": "application/pdf",
                }
            ]
        },
    )
    db_session.add(job)
    db_session.commit()
    owner.client.post(
        f"/api/evaluations/{created['evaluation_id']}/trash",
        headers={"X-CSRF-Token": owner.csrf},
    )

    response = admin.client.request(
        "DELETE",
        f"/api/evaluations/{created['evaluation_id']}",
        headers={"X-CSRF-Token": admin.csrf},
        json={"reason": "验证路径越界保护"},
    )

    assert response.status_code == 500
    assert response.json()["error"]["code"] == "report_cleanup_failed"
    assert outside_file.read_bytes() == b"must-not-change"
    db_session.expire_all()
    assert db_session.get(Evaluation, UUID(created["evaluation_id"])) is not None
