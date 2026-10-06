import io
import json
import tarfile
from datetime import UTC, datetime

from guardianbackend.config import Settings
from guardianbackend.domain import new_import_run_id, new_import_shard_id, new_owned_source_id
from guardianbackend.files import (
    InMemorySourceFileRepository,
    InMemorySourceTimeCoverageRepository,
    SourceFileService,
)
from guardianbackend.imports import (
    ImportRun,
    ImportShard,
    ImportWorkerService,
    InMemoryImportRunRepository,
    InMemoryImportShardRepository,
)
from guardianbackend.sources import InMemoryOwnedSourceRepository, OwnedSource
from guardianbackend.storage import build_object_store, build_transport_object_path


def _build_transport_shard_bytes(
    *,
    archive_path: str = "files/notes/note.txt",
    original_relative_path: str = "notes/note.txt",
    filename: str = "note.txt",
    content_hash: str = "worker-test-hash",
    file_bytes: bytes = b"hello from local import worker test\n",
) -> bytes:
    manifest = {
        "files": [
            {
                "archive_path": archive_path,
                "original_relative_path": original_relative_path,
                "filename": filename,
                "content_hash": content_hash,
                "size_bytes": len(file_bytes),
                "content_type": "text/plain",
                "source_modified_at": "2026-01-01T09:00:00Z",
            }
        ]
    }
    archive_buffer = io.BytesIO()
    with tarfile.open(fileobj=archive_buffer, mode="w") as archive:
        manifest_bytes = json.dumps(manifest).encode("utf-8")
        manifest_info = tarfile.TarInfo(name="manifest.json")
        manifest_info.size = len(manifest_bytes)
        archive.addfile(manifest_info, io.BytesIO(manifest_bytes))

        file_info = tarfile.TarInfo(name=archive_path)
        file_info.size = len(file_bytes)
        archive.addfile(file_info, io.BytesIO(file_bytes))
    return archive_buffer.getvalue()


def test_import_worker_processes_uploaded_shard(tmp_path) -> None:
    settings = Settings(
        gcp_project_id=None,
        gcs_bucket_name="test-bucket",
        local_storage_root=str(tmp_path),
    )
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    source_file_service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    import_run_repository = InMemoryImportRunRepository()
    import_shard_repository = InMemoryImportShardRepository()
    object_store = build_object_store(settings)

    owned_source_id = new_owned_source_id()
    import_run_id = new_import_run_id()
    shard_object_path = build_transport_object_path(
        transport_prefix=settings.gcs_transport_prefix,
        user_id="user_worker123",
        owned_source_id=owned_source_id,
        import_run_id=import_run_id,
        filename="shard-0000.tar",
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id=owned_source_id,
            user_id="user_worker123",
            source_id="screenpipe",
            display_name="Worker Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            current_import_run_id=import_run_id,
        )
    )
    import_run_repository.save_import_run(
        ImportRun(
            import_run_id=import_run_id,
            user_id="user_worker123",
            owned_source_id=owned_source_id,
            source_id="screenpipe",
            status="processing",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            uploaded_transport_shard_count=1,
            transport_shard_count=1,
        )
    )
    shard_id = new_import_shard_id()
    import_shard_repository.save_import_shard(
        ImportShard(
            import_shard_id=shard_id,
            import_run_id=import_run_id,
            user_id="user_worker123",
            owned_source_id=owned_source_id,
            status="uploaded",
            shard_index=0,
            filename="shard-0000.tar",
            object_path=shard_object_path,
            content_hash="worker-transport-hash",
            file_count=1,
            total_size_bytes=128,
            created_at=datetime.now(tz=UTC),
            uploaded_at=datetime.now(tz=UTC),
        )
    )
    object_store.upload_bytes(
        bucket="test-bucket",
        object_path=shard_object_path,
        data=_build_transport_shard_bytes(),
        content_type="application/x-tar",
    )

    worker = ImportWorkerService(
        settings,
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        object_store,
    )
    result = worker.process_import_run(import_run_id)

    assert result.status == "completed"
    assert result.processed_shard_count == 1
    assert result.canonical_file_count == 1

    saved_run = import_run_repository.get_import_run(import_run_id)
    assert saved_run is not None
    assert saved_run.status == "completed"

    saved_shards = import_shard_repository.list_import_shards_for_run(import_run_id)
    assert len(saved_shards) == 1
    assert saved_shards[0].status == "processed"

    source_files = source_file_service.list_source_files_for_owned_source(
        "user_worker123",
        owned_source_id,
    )
    assert len(source_files) == 1
    assert source_files[0].content_hash == "worker-test-hash"
    assert object_store.object_exists(
        bucket="test-bucket",
        object_path=source_files[0].object_path,
    )
    assert not object_store.object_exists(
        bucket="test-bucket",
        object_path=shard_object_path,
    )

    updated_source = owned_source_repository.get_owned_source(owned_source_id)
    assert updated_source is not None
    assert updated_source.current_import_run_id is None
    assert updated_source.last_import_completed_at is not None


def test_import_worker_skips_duplicate_execution_for_claimed_shard(tmp_path) -> None:
    settings = Settings(
        gcp_project_id=None,
        gcs_bucket_name="test-bucket",
        local_storage_root=str(tmp_path),
    )
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    source_file_service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    import_run_repository = InMemoryImportRunRepository()
    import_shard_repository = InMemoryImportShardRepository()
    object_store = build_object_store(settings)

    owned_source_id = new_owned_source_id()
    import_run_id = new_import_run_id()
    shard_object_path = build_transport_object_path(
        transport_prefix=settings.gcs_transport_prefix,
        user_id="user_worker123",
        owned_source_id=owned_source_id,
        import_run_id=import_run_id,
        filename="shard-0000.tar",
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id=owned_source_id,
            user_id="user_worker123",
            source_id="screenpipe",
            display_name="Worker Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            current_import_run_id=import_run_id,
        )
    )
    import_run_repository.save_import_run(
        ImportRun(
            import_run_id=import_run_id,
            user_id="user_worker123",
            owned_source_id=owned_source_id,
            source_id="screenpipe",
            status="processing",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            uploaded_transport_shard_count=1,
            transport_shard_count=1,
        )
    )
    shard_id = new_import_shard_id()
    import_shard_repository.save_import_shard(
        ImportShard(
            import_shard_id=shard_id,
            import_run_id=import_run_id,
            user_id="user_worker123",
            owned_source_id=owned_source_id,
            status="uploaded",
            shard_index=0,
            filename="shard-0000.tar",
            object_path=shard_object_path,
            content_hash="worker-transport-hash",
            file_count=1,
            total_size_bytes=128,
            created_at=datetime.now(tz=UTC),
            uploaded_at=datetime.now(tz=UTC),
        )
    )
    object_store.upload_bytes(
        bucket="test-bucket",
        object_path=shard_object_path,
        data=_build_transport_shard_bytes(),
        content_type="application/x-tar",
    )

    claimed = import_shard_repository.claim_uploaded_shard(shard_id)
    assert claimed is not None

    worker = ImportWorkerService(
        settings,
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        object_store,
    )
    result = worker.process_import_run(import_run_id)

    assert result.processed_shard_count == 0
    assert result.canonical_file_count == 0

    saved_run = import_run_repository.get_import_run(import_run_id)
    assert saved_run is not None
    assert saved_run.status == "processing"

    source_files = source_file_service.list_source_files_for_owned_source(
        "user_worker123",
        owned_source_id,
    )
    assert source_files == []


def test_import_worker_recomputes_run_progress_from_processed_shards(tmp_path) -> None:
    settings = Settings(
        gcp_project_id=None,
        gcs_bucket_name="test-bucket",
        local_storage_root=str(tmp_path),
    )
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    source_file_service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    import_run_repository = InMemoryImportRunRepository()
    import_shard_repository = InMemoryImportShardRepository()
    object_store = build_object_store(settings)

    owned_source_id = new_owned_source_id()
    import_run_id = new_import_run_id()
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id=owned_source_id,
            user_id="user_worker123",
            source_id="screenpipe",
            display_name="Worker Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            current_import_run_id=import_run_id,
        )
    )
    import_run_repository.save_import_run(
        ImportRun(
            import_run_id=import_run_id,
            user_id="user_worker123",
            owned_source_id=owned_source_id,
            source_id="screenpipe",
            status="processing",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            uploaded_transport_shard_count=2,
            transport_shard_count=2,
        )
    )

    shard_specs = [
        ("shard-0000.tar", "notes/alpha.txt", "alpha-hash", b"alpha\n"),
        ("shard-0001.tar", "notes/bravo.txt", "bravo-hash", b"bravo\n"),
    ]
    shard_ids: list[str] = []
    for index, (filename, relative_path, content_hash, file_bytes) in enumerate(shard_specs):
        shard_id = new_import_shard_id()
        shard_ids.append(shard_id)
        shard_object_path = build_transport_object_path(
            transport_prefix=settings.gcs_transport_prefix,
            user_id="user_worker123",
            owned_source_id=owned_source_id,
            import_run_id=import_run_id,
            filename=filename,
        )
        import_shard_repository.save_import_shard(
            ImportShard(
                import_shard_id=shard_id,
                import_run_id=import_run_id,
                user_id="user_worker123",
                owned_source_id=owned_source_id,
                status="uploaded",
                shard_index=index,
                filename=filename,
                object_path=shard_object_path,
                content_hash=f"transport-{content_hash}",
                file_count=1,
                total_size_bytes=len(file_bytes),
                created_at=datetime.now(tz=UTC),
                uploaded_at=datetime.now(tz=UTC),
            )
        )
        object_store.upload_bytes(
            bucket="test-bucket",
            object_path=shard_object_path,
            data=_build_transport_shard_bytes(
                archive_path=f"files/{relative_path}",
                original_relative_path=relative_path,
                filename=relative_path.rsplit("/", 1)[-1],
                content_hash=content_hash,
                file_bytes=file_bytes,
            ),
            content_type="application/x-tar",
        )

    worker = ImportWorkerService(
        settings,
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        object_store,
    )

    first_result = worker.process_import_shard(
        import_run_id=import_run_id,
        import_shard_id=shard_ids[0],
    )
    assert first_result.import_run_status == "processing"
    assert first_result.canonical_file_count == 1

    # Simulate a stale concurrent worker overwriting the run counters
    # before the next shard finishes.
    import_run_repository.save_import_run(
        ImportRun(
            import_run_id=import_run_id,
            user_id="user_worker123",
            owned_source_id=owned_source_id,
            source_id="screenpipe",
            status="processing",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
            uploaded_transport_shard_count=2,
            transport_shard_count=2,
            processed_transport_shard_count=0,
            canonical_file_count=0,
        )
    )

    second_result = worker.process_import_shard(
        import_run_id=import_run_id,
        import_shard_id=shard_ids[1],
    )
    assert second_result.import_run_status == "completed"
    assert second_result.canonical_file_count == 2

    saved_run = import_run_repository.get_import_run(import_run_id)
    assert saved_run is not None
    assert saved_run.status == "completed"
    assert saved_run.processed_transport_shard_count == 2
    assert saved_run.canonical_file_count == 2

    source_files = source_file_service.list_source_files_for_owned_source(
        "user_worker123",
        owned_source_id,
    )
    assert {source_file.content_hash for source_file in source_files} == {
        "alpha-hash",
        "bravo-hash",
    }
