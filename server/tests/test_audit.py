import json

from tests.support import create_evaluation


def test_only_admin_can_query_audit(authenticated_client_factory):
    teacher = authenticated_client_factory(username="audit-teacher")

    response = teacher.client.get("/api/admin/audit")

    assert response.status_code == 403


def test_admin_audit_query_is_paginated_and_secret_free(authenticated_client_factory):
    teacher = authenticated_client_factory(username="audit-owner")
    admin = authenticated_client_factory(username="audit-admin", role="admin")
    create_evaluation(teacher)

    response = admin.client.get("/api/admin/audit", params={"action": "evaluation_created"})

    assert response.status_code == 200
    body = response.json()
    assert len(body["items"]) == 1
    assert body["items"][0]["action"] == "evaluation_created"
    serialized = json.dumps(body, ensure_ascii=False).lower()
    for forbidden in ("password", "authorization", "cookie", "api_key", "payload"):
        assert forbidden not in serialized
