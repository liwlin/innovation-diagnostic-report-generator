from __future__ import annotations


def test_root_serves_nas_shell_and_runtime_config(client):
    shell = client.get("/")
    runtime = client.get("/runtime-config.js")

    assert shell.status_code == 200
    assert '<main id="app"' in shell.text
    assert "/nas-static/app.js" in shell.text
    assert runtime.status_code == 200
    assert '"storageMode":"api"' in runtime.text
    assert '"appVersion":"test"' in runtime.text
    assert runtime.headers["cache-control"] == "no-store"


def test_editor_injects_api_runtime_before_shared_runtime(client):
    response = client.get(
        "/editor", params={"evaluation_id": "11111111-1111-4111-8111-111111111111"}
    )

    assert response.status_code == 200
    assert response.text.index("/runtime-config.js") < response.text.index(
        "./shared/runtime-config.js"
    )
    assert "科创体验报告 · 生成器" in response.text


def test_static_security_headers_are_strict_for_shell_and_scoped_for_editor(client):
    shell = client.get("/")
    editor = client.get("/editor")

    assert shell.headers["x-content-type-options"] == "nosniff"
    assert shell.headers["x-frame-options"] == "DENY"
    assert shell.headers["referrer-policy"] == "same-origin"
    assert "'unsafe-inline'" not in shell.headers["content-security-policy"]
    assert (
        "script-src 'self' 'unsafe-inline' 'unsafe-eval'"
        in editor.headers["content-security-policy"]
    )
    assert "connect-src 'self' https:" in editor.headers["content-security-policy"]
    assert "script-src 'self' https:" not in editor.headers["content-security-policy"]


def test_explicit_static_paths_work_without_directory_listing(client):
    for path in (
        "/support.js",
        "/doc-page.js",
        "/assets/logo-lockup.png",
        "/shared/runtime-config.js",
        "/nas-static/app.css",
    ):
        response = client.get(path)
        assert response.status_code == 200, path
        assert "Directory listing" not in response.text

    assert client.get("/assets/../server/pyproject.toml").status_code != 200
    api_missing = client.get("/api/route-that-does-not-exist")
    assert api_missing.status_code == 404
    assert '<main id="app"' not in api_missing.text
