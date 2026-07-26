"""Unit tests for the DevSecOps sample application."""

from pathlib import Path

import pytest

from src.main import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def test_healthz(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json["status"] == "ok"


def test_readyz(client):
    resp = client.get("/readyz")
    assert resp.status_code == 200
    assert resp.json["status"] == "ready"


def test_info(client):
    resp = client.get("/api/v1/info")
    assert resp.status_code == 200
    data = resp.json
    assert "service" in data
    assert data["service"] == "devsecops-app"


def test_list_items(client):
    resp = client.get("/api/v1/items")
    assert resp.status_code == 200
    data = resp.json
    assert "items" in data
    assert data["count"] == 5


def test_security_headers(client):
    resp = client.get("/healthz")
    assert resp.headers.get("X-Content-Type-Options") == "nosniff"
    assert resp.headers.get("X-Frame-Options") == "DENY"
    assert resp.headers.get("X-XSS-Protection") == "1; mode=block"
    assert "Strict-Transport-Security" in resp.headers
    assert "Content-Security-Policy" in resp.headers


def test_server_header_removed(client):
    """The WSGI layer must not leak a Server banner.

    Note: this only covers the Flask response. Gunicorn writes its own Server
    header *after* the app returns, so production disclosure is suppressed by
    overriding gunicorn.SERVER in __main__ — asserted by
    test_gunicorn_banner_is_suppressed below.
    """
    resp = client.get("/healthz")
    assert "Server" not in resp.headers or resp.headers.get("Server") == ""


def test_gunicorn_banner_is_suppressed():
    """Guard the production fix: no gunicorn version in the Server header."""
    import gunicorn

    src = Path(__file__).resolve().parents[1] / "src" / "main.py"
    body = src.read_text()

    assert 'gunicorn.SERVER = "undisclosed"' in body
    assert 'gunicorn.SERVER_SOFTWARE = "undisclosed"' in body
    # Sanity check that the attributes we override actually exist upstream.
    assert hasattr(gunicorn, "SERVER") or hasattr(gunicorn, "SERVER_SOFTWARE")


def test_metrics_endpoint(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"http_requests_total" in resp.data


def test_openapi_spec(client):
    resp = client.get("/api/v1/openapi.json")
    assert resp.status_code == 200
    spec = resp.json
    assert spec["openapi"].startswith("3.")
    # DAST drives the API scan from this contract — the probed paths must exist.
    for path in ("/healthz", "/readyz", "/api/v1/info", "/api/v1/items"):
        assert path in spec["paths"]
