import hashlib
from datetime import UTC, datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from guardianbackend.domain import new_import_run_id, new_owned_source_id
from guardianbackend.files import (
    InMemorySourceFileRepository,
    InMemorySourceTimeCoverageRepository,
    SourceFileService,
)
from guardianbackend.imports import (
    ImportRun,
    ImportRunCreateRequest,
    ImportService,
    ImportShardCreateRequest,
    InMemoryImportRunRepository,
    InMemoryImportShardRepository,
)
from guardianbackend.sources import InMemoryOwnedSourceRepository, OwnedSource
from guardianbackend.storage import LocalObjectStore


class RecordingDispatcher:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []

    def dispatch_import_shard(self, *, import_run_id: str, import_shard_id: str) -> None:
        self.calls.append((import_run_id, import_shard_id))


def test_complete_import_run_dispatches_each_uploaded_shard() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    import_run_repository = InMemoryImportRunRepository()
    import_shard_repository = InMemoryImportShardRepository()
    source_file_service = SourceFileService(
        InMemorySourceFileRepository(),
        InMemorySourceTimeCoverageRepository(),
        owned_source_repository,
    )
    dispatcher = RecordingDispatcher()

    owned_source_id = new_owned_source_id()
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id=owned_source_id,
            user_id="user_import123",
            source_id="screenpipe",
            display_name="Dispatch Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )
    import_run_id = new_import_run_id()
    import_run_repository.save_import_run(
        ImportRun(
            import_run_id=import_run_id,
            user_id="user_import123",
            owned_source_id=owned_source_id,
            source_id="screenpipe",
            status="uploading",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    service = ImportService(
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        dispatcher,
    )

    service.create_import_shards(
        "user_import123",
        owned_source_id,
        import_run_id,
        ImportShardCreateRequest(
            shards=[
                {
                    "shard_index": 0,
                    "filename": "shard-0000.tar",
                    "object_path": "tmp-imports/u/s/i/shard-0000.tar",
                    "content_hash": "hash-0000",
                    "file_count": 100,
                    "total_size_bytes": 1024,
                },
                {
                    "shard_index": 1,
                    "filename": "shard-0001.tar",
                    "object_path": "tmp-imports/u/s/i/shard-0001.tar",
                    "content_hash": "hash-0001",
                    "file_count": 100,
                    "total_size_bytes": 1024,
                },
            ]
        ),
    )

    result = service.complete_import_run("user_import123", owned_source_id, import_run_id)

    assert result.status == "processing"
    assert result.uploaded_transport_shard_count == 2
    assert len(dispatcher.calls) == 2
    assert {call[0] for call in dispatcher.calls} == {import_run_id}


def test_list_import_queue_for_user_filters_and_orders_runs() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    import_run_repository = InMemoryImportRunRepository()
    import_shard_repository = InMemoryImportShardRepository()
    source_file_service = SourceFileService(
        InMemorySourceFileRepository(),
        InMemorySourceTimeCoverageRepository(),
        owned_source_repository,
    )
    dispatcher = RecordingDispatcher()

    owned_source_a = new_owned_source_id()
    owned_source_b = new_owned_source_id()
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id=owned_source_a,
            user_id="user_import123",
            source_id="screenpipe",
            display_name="Alpha Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id=owned_source_b,
            user_id="user_import123",
            source_id="screenpipe",
            display_name="Bravo Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    service = ImportService(
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        dispatcher,
    )

    older_run = service.create_import_run(
        "user_import123",
        owned_source_a,
        ImportRunCreateRequest(client_id="a"),
    )
    newer_run = service.create_import_run(
        "user_import123",
        owned_source_b,
        ImportRunCreateRequest(client_id="b"),
    )
    import_run_repository.save_import_run(
        older_run.model_copy(update={"status": "processing"})
    )
    import_run_repository.save_import_run(
        newer_run.model_copy(update={"status": "completed"})
    )

    queue = service.list_import_queue_for_user("user_import123", limit=10)
    assert len(queue) == 1
    assert queue[0].import_run_id == older_run.import_run_id
    assert queue[0].source_display_name == "Alpha Source"

    queue_with_completed = service.list_import_queue_for_user(
        "user_import123",
        limit=10,
        include_completed=True,
    )
    assert [item.import_run_id for item in queue_with_completed] == [
        newer_run.import_run_id,
        older_run.import_run_id,
    ]


def test_upload_import_shard_content_updates_storage_and_progress() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    import_run_repository = InMemoryImportRunRepository()
    import_shard_repository = InMemoryImportShardRepository()
    source_file_service = SourceFileService(
        InMemorySourceFileRepository(),
        InMemorySourceTimeCoverageRepository(),
        owned_source_repository,
    )
    dispatcher = RecordingDispatcher()

    owned_source_id = new_owned_source_id()
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id=owned_source_id,
            user_id="user_import123",
            source_id="screenpipe",
            display_name="Upload Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    service = ImportService(
        import_run_repository,
        import_shard_repository,
        owned_source_repository,
        source_file_service,
        dispatcher,
    )

    import_run = service.create_import_run(
        "user_import123",
        owned_source_id,
        ImportRunCreateRequest(client_id="desktop"),
    )
    payload = b"desktop-transport-bytes"
    content_hash = hashlib.sha256(payload).hexdigest()
    created_shard = service.create_import_shards(
        "user_import123",
        owned_source_id,
        import_run.import_run_id,
        ImportShardCreateRequest(
            shards=[
                {
                    "shard_index": 0,
                    "filename": "shard-0000.tar",
                    "content_hash": content_hash,
                    "file_count": 2,
                    "total_size_bytes": 512,
                }
            ]
        ),
        transport_prefix="tmp-imports",
    )[0]

    with TemporaryDirectory() as temp_dir:
        object_store = LocalObjectStore(Path(temp_dir))
        saved_shard = service.upload_import_shard_content(
            "user_import123",
            owned_source_id,
            import_run.import_run_id,
            created_shard.import_shard_id,
            data=payload,
            bucket="guardian-local",
            object_store=object_store,
            content_type="application/x-tar",
        )

        assert saved_shard.status == "uploaded"
        assert object_store.object_exists(
            bucket="guardian-local",
            object_path=saved_shard.object_path,
        )
        refreshed_run = import_run_repository.get_import_run(import_run.import_run_id)
        assert refreshed_run is not None
        assert refreshed_run.uploaded_transport_shard_count == 1
