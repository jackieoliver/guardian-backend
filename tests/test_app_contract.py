from fastapi.testclient import TestClient

from guardianbackend.api.app import create_app
from guardianbackend.config import Settings


def _app_client() -> TestClient:
    return TestClient(create_app(Settings(gcp_project_id=None, gcs_bucket_name=None)))


def test_health_returns_ok() -> None:
    response = _app_client().get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_ready_returns_ready() -> None:
    response = _app_client().get("/ready")

    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_me_requires_bearer_token() -> None:
    response = _app_client().get("/me")

    assert response.status_code == 401
    assert response.json()["detail"] == "Missing bearer token"


def test_vm_access_requires_bearer_token() -> None:
    response = _app_client().get("/me/vm-access")

    assert response.status_code == 401
    assert response.json()["detail"] == "Missing bearer token"
