import hashlib
from datetime import UTC, datetime

from fastapi.testclient import TestClient

from guardianbackend.api.app import create_app
from guardianbackend.auth import issue_dummy_user_token
from guardianbackend.config import Settings
from guardianbackend.domain import new_source_file_id
from guardianbackend.files import SourceFile


def _client_and_headers() -> tuple[TestClient, dict[str, str]]:
    settings = Settings(
        gcp_project_id=None,
        gcs_bucket_name=None,
        dummy_user_signing_key="dummy-signing-key",
    )
    token = issue_dummy_user_token(
        signing_key="dummy-signing-key",
        user_id="user_import123",
        email="import-user@guardian.local",
        name="Import User",
    )
    client = TestClient(create_app(settings))
    headers = {"Authorization": f"Bearer {token}"}
    source_response = client.post(
        "/me/sources",
        headers=headers,
        json={"source_id": "screenpipe", "display_name": "Import Source"},
    )
    assert source_response.status_code == 201
    return client, headers | {"X-Owned-Source-Id": source_response.json()["owned_source_id"]}


def test_import_run_contract_flow() -> None:
    client, headers = _client_and_headers()
    owned_source_id = headers["X-Owned-Source-Id"]

    create_run_response = client.post(
        f"/me/sources/{owned_source_id}/imports",
        headers={"Authorization": headers["Authorization"]},
        json={
            "client_id": "cli-smoke",
            "source_snapshot_label": "snapshot-a",
            "total_candidate_file_count": 3,
            "total_candidate_size_bytes": 1024,
        },
    )
    assert create_run_response.status_code == 201
    import_run = create_run_response.json()

    get_run_response = client.get(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}",
        headers={"Authorization": headers["Authorization"]},
    )
    assert get_run_response.status_code == 200
    assert get_run_response.json()["status"] == "created"

    list_runs_response = client.get(
        f"/me/sources/{owned_source_id}/imports",
        headers={"Authorization": headers["Authorization"]},
    )
    assert list_runs_response.status_code == 200
    assert len(list_runs_response.json()) == 1

    create_shards_response = client.post(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}/shards",
        headers={"Authorization": headers["Authorization"]},
        json={
            "shards": [
                {
                    "shard_index": 0,
                    "filename": "shard-0000.tar",
                    "object_path": "tmp-imports/user_import123/source/import/shard-0000.tar",
                    "content_hash": "hash-0000",
                    "file_count": 3,
                    "total_size_bytes": 1024,
                }
            ]
        },
    )
    assert create_shards_response.status_code == 201
    created_shards = create_shards_response.json()
    assert len(created_shards) == 1

    shard_payload = b"guardian-import-shard"
    upload_shard_response = client.put(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}/shards/{created_shards[0]['import_shard_id']}/content",
        headers={
            "Authorization": headers["Authorization"],
            "Content-Type": "application/x-tar",
        },
        content=shard_payload,
    )
    assert upload_shard_response.status_code == 400

    correct_hash = hashlib.sha256(shard_payload).hexdigest()
    create_matching_shards_response = client.post(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}/shards",
        headers={"Authorization": headers["Authorization"]},
        json={
            "shards": [
                {
                    "shard_index": 1,
                    "filename": "shard-0001.tar",
                    "content_hash": correct_hash,
                    "file_count": 3,
                    "total_size_bytes": 1024,
                }
            ]
        },
    )
    assert create_matching_shards_response.status_code == 201
    uploaded_shard = create_matching_shards_response.json()[0]

    upload_shard_response = client.put(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}/shards/{uploaded_shard['import_shard_id']}/content",
        headers={
            "Authorization": headers["Authorization"],
            "Content-Type": "application/x-tar",
        },
        content=shard_payload,
    )
    assert upload_shard_response.status_code == 200
    assert upload_shard_response.json()["status"] == "uploaded"
    assert upload_shard_response.json()["object_path"].endswith("/shard-0001.tar")

    queue_before_complete_response = client.get(
        "/me/imports/queue",
        headers={"Authorization": headers["Authorization"]},
    )
    assert queue_before_complete_response.status_code == 200
    queue_before_complete = queue_before_complete_response.json()
    assert len(queue_before_complete) == 1
    assert queue_before_complete[0]["import_run_id"] == import_run["import_run_id"]
    assert queue_before_complete[0]["source_display_name"] == "Import Source"
    assert queue_before_complete[0]["status"] == "uploading"
    assert queue_before_complete[0]["uploaded_transport_shard_count"] == 1

    complete_run_response = client.post(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}/complete",
        headers={"Authorization": headers["Authorization"]},
    )
    assert complete_run_response.status_code == 200
    assert complete_run_response.json()["status"] == "processing"
    assert complete_run_response.json()["uploaded_transport_shard_count"] == 2

    delete_during_processing_response = client.delete(
        f"/me/sources/{owned_source_id}",
        headers={"Authorization": headers["Authorization"]},
    )
    assert delete_during_processing_response.status_code == 409

    cancel_run_response = client.post(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}/cancel",
        headers={"Authorization": headers["Authorization"]},
        json={"error": "user canceled smoke run"},
    )
    assert cancel_run_response.status_code == 200
    assert cancel_run_response.json()["status"] == "canceled"

    queue_after_cancel_response = client.get(
        "/me/imports/queue",
        headers={"Authorization": headers["Authorization"]},
    )
    assert queue_after_cancel_response.status_code == 200
    assert queue_after_cancel_response.json() == []

    queue_with_completed_response = client.get(
        "/me/imports/queue?include_completed=true",
        headers={"Authorization": headers["Authorization"]},
    )
    assert queue_with_completed_response.status_code == 200
    queue_with_completed = queue_with_completed_response.json()
    assert len(queue_with_completed) == 1
    assert queue_with_completed[0]["status"] == "canceled"

    delete_after_cancel_response = client.delete(
        f"/me/sources/{owned_source_id}",
        headers={"Authorization": headers["Authorization"]},
    )
    assert delete_after_cancel_response.status_code == 204


def test_source_files_contract_flow() -> None:
    client, headers = _client_and_headers()
    owned_source_id = headers["X-Owned-Source-Id"]

    warm_response = client.get(
        f"/me/sources/{owned_source_id}/files",
        headers={"Authorization": headers["Authorization"]},
    )
    assert warm_response.status_code == 200
    assert warm_response.json() == []

    empty_coverage_response = client.get(
        f"/me/sources/{owned_source_id}/coverage?year=2026",
        headers={"Authorization": headers["Authorization"]},
    )
    assert empty_coverage_response.status_code == 200
    assert empty_coverage_response.json()["covered_hour_count"] == 0

    source_file_service = client.app.state.source_file_service
    source_file_service._source_file_repository.save_source_file(  # noqa: SLF001
        SourceFile(
            source_file_id=new_source_file_id(),
            import_run_id="import_seed123",
            user_id="user_import123",
            owned_source_id=owned_source_id,
            source_id="screenpipe",
            content_hash="seed-hash-123",
            bucket="guardian-ingest-bucket-3-26",
            object_path=f"files/user_import123/{owned_source_id}/seed-file.txt",
            filename="seed-file.txt",
            materialized_filename="seed-file-seed-hash.txt",
            content_type="text/plain",
            size_bytes=64,
            original_relative_path="seed/seed-file.txt",
            source_modified_at=datetime(2026, 1, 1, 9, 0, tzinfo=UTC),
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    list_files_response = client.get(
        f"/me/sources/{owned_source_id}/files",
        headers={"Authorization": headers["Authorization"]},
    )
    assert list_files_response.status_code == 200
    body = list_files_response.json()
    assert len(body) == 1
    assert body[0]["owned_source_id"] == owned_source_id
    assert body[0]["original_relative_path"] == "seed/seed-file.txt"
    assert body[0]["metadata_state"] == "pending"

    update_metadata_response = client.patch(
        f"/me/sources/{owned_source_id}/files/{body[0]['source_file_id']}/metadata",
        headers={"Authorization": headers["Authorization"]},
        json={
            "metadata_state": "inferred",
            "time_start": "2026-01-01T09:00:00Z",
            "time_end": "2026-01-01T09:10:00Z",
            "interval_confidence": 0.8,
            "processing_version": "interval-v1",
            "metadata_artifact_uri": "gs://guardian-ingest-bucket-3-26/artifacts/seed.json",
        },
    )
    assert update_metadata_response.status_code == 200
    assert update_metadata_response.json()["metadata_state"] == "inferred"
    assert update_metadata_response.json()["time_start"] == "2026-01-01T09:00:00Z"

    coverage_response = client.get(
        f"/me/sources/{owned_source_id}/coverage?year=2026",
        headers={"Authorization": headers["Authorization"]},
    )
    assert coverage_response.status_code == 200
    coverage_body = coverage_response.json()
    assert coverage_body["covered_hour_count"] == 1
    assert coverage_body["coverage"][9] is True


def test_import_plan_contract_flow() -> None:
    client, headers = _client_and_headers()
    owned_source_id = headers["X-Owned-Source-Id"]

    warm_response = client.get(
        f"/me/sources/{owned_source_id}/files",
        headers={"Authorization": headers["Authorization"]},
    )
    assert warm_response.status_code == 200

    source_file_service = client.app.state.source_file_service
    source_file_service._source_file_repository.save_source_file(  # noqa: SLF001
        SourceFile(
            source_file_id=new_source_file_id(),
            import_run_id="import_seed_plan123",
            user_id="user_import123",
            owned_source_id=owned_source_id,
            source_id="screenpipe",
            content_hash="known-hash-123",
            bucket="guardian-ingest-bucket-3-26",
            object_path=f"files/user_import123/{owned_source_id}/known.txt",
            filename="known.txt",
            materialized_filename="known-knownhash.txt",
            content_type="text/plain",
            size_bytes=128,
            original_relative_path="seed/known.txt",
            source_modified_at=datetime(2026, 1, 2, 9, 0, tzinfo=UTC),
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    create_run_response = client.post(
        f"/me/sources/{owned_source_id}/imports",
        headers={"Authorization": headers["Authorization"]},
        json={
            "client_id": "cli-plan-smoke",
            "source_snapshot_label": "snapshot-plan",
            "total_candidate_file_count": 2,
            "total_candidate_size_bytes": 256,
        },
    )
    assert create_run_response.status_code == 201
    import_run = create_run_response.json()

    plan_response = client.post(
        f"/me/sources/{owned_source_id}/imports/{import_run['import_run_id']}/plan",
        headers={"Authorization": headers["Authorization"]},
        json={
            "candidates": [
                {
                    "content_hash": "known-hash-123",
                    "original_relative_path": "seed/known.txt",
                    "size_bytes": 128,
                    "source_modified_at": "2026-01-02T09:00:00Z",
                },
                {
                    "content_hash": "missing-hash-456",
                    "original_relative_path": "seed/missing.txt",
                    "size_bytes": 64,
                    "source_modified_at": "2026-01-03T09:00:00Z",
                },
            ]
        },
    )
    assert plan_response.status_code == 200
    body = plan_response.json()
    assert body["known_count"] == 1
    assert body["missing_count"] == 1
    assert body["known"][0]["content_hash"] == "known-hash-123"
    assert body["missing"][0]["content_hash"] == "missing-hash-456"
