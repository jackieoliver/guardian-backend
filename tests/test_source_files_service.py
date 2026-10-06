from datetime import UTC, datetime

from guardianbackend.files import (
    InMemorySourceFileRepository,
    InMemorySourceTimeCoverageRepository,
    SourceFileCreateInput,
    SourceFileMetadataState,
    SourceFileMetadataUpdateRequest,
    SourceFileService,
)
from guardianbackend.sources import InMemoryOwnedSourceRepository, OwnedSource


def test_record_and_list_source_files() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id="source_test123",
            user_id="user_test123",
            source_id="screenpipe",
            display_name="Screenpipe Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    created = service.record_source_files_for_import(
        user_id="user_test123",
        owned_source_id="source_test123",
        import_run_id="import_test123",
        source_id="screenpipe",
        files=[
            SourceFileCreateInput(
                content_hash="hash123",
                bucket="guardian-ingest-bucket-3-26",
                object_path="files/user_test123/source_test123/example.txt",
                filename="example.txt",
                content_type="text/plain",
                size_bytes=123,
                original_relative_path="notes/example.txt",
                source_modified_at=datetime(2026, 1, 1, 9, 0, tzinfo=UTC),
            )
        ],
    )

    assert len(created) == 1
    assert created[0].materialized_filename.startswith("example-")

    listed = service.list_source_files_for_owned_source("user_test123", "source_test123")
    assert len(listed) == 1
    assert listed[0].original_relative_path == "notes/example.txt"
    assert listed[0].metadata_state == SourceFileMetadataState.INFERRED
    assert listed[0].time_basis == "source_modified_at"

    found = service.find_source_files_by_hashes_for_owned_source(
        "user_test123",
        "source_test123",
        {"hash123", "missing-hash"},
    )
    assert len(found) == 1
    assert found[0].content_hash == "hash123"


def test_list_source_files_respects_limit() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id="source_test123",
            user_id="user_test123",
            source_id="screenpipe",
            display_name="Screenpipe Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    service.record_source_files_for_import(
        user_id="user_test123",
        owned_source_id="source_test123",
        import_run_id="import_test123",
        source_id="screenpipe",
        files=[
            SourceFileCreateInput(
                content_hash=f"hash{i}",
                bucket="guardian-ingest-bucket-3-26",
                object_path=f"files/user_test123/source_test123/file-{i}.txt",
                filename=f"file-{i}.txt",
                content_type="text/plain",
                size_bytes=123,
                original_relative_path=f"notes/file-{i}.txt",
                source_modified_at=datetime(2026, 1, 1, 9, 0, tzinfo=UTC),
            )
            for i in range(3)
        ],
    )

    listed = service.list_source_files_for_owned_source(
        "user_test123",
        "source_test123",
        limit=2,
    )
    assert len(listed) == 2


def test_update_source_file_metadata_state_machine() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id="source_test123",
            user_id="user_test123",
            source_id="screenpipe",
            display_name="Screenpipe Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    created = service.record_source_files_for_import(
        user_id="user_test123",
        owned_source_id="source_test123",
        import_run_id="import_test123",
        source_id="screenpipe",
        files=[
            SourceFileCreateInput(
                content_hash="hash123",
                bucket="guardian-ingest-bucket-3-26",
                object_path="files/user_test123/source_test123/example.txt",
                filename="example.txt",
                content_type="text/plain",
                size_bytes=123,
                original_relative_path="notes/example.txt",
                source_modified_at=datetime(2026, 1, 1, 9, 0, tzinfo=UTC),
            )
        ],
    )
    source_file_id = created[0].source_file_id

    inferred = service.update_source_file_metadata(
        user_id="user_test123",
        owned_source_id="source_test123",
        source_file_id=source_file_id,
        request=SourceFileMetadataUpdateRequest(
            metadata_state=SourceFileMetadataState.INFERRED,
            time_start=datetime(2026, 1, 1, 9, 0, tzinfo=UTC),
            time_end=datetime(2026, 1, 1, 9, 15, tzinfo=UTC),
            interval_confidence=0.82,
            processing_version="interval-v1",
            metadata_artifact_uri="gs://guardian-ingest-bucket-3-26/artifacts/example.json",
        ),
    )
    assert inferred.metadata_state == SourceFileMetadataState.INFERRED
    assert inferred.interval_confidence == 0.82

    reviewed = service.update_source_file_metadata(
        user_id="user_test123",
        owned_source_id="source_test123",
        source_file_id=source_file_id,
        request=SourceFileMetadataUpdateRequest(
            metadata_state=SourceFileMetadataState.REVIEWED,
            time_start=datetime(2026, 1, 1, 9, 1, tzinfo=UTC),
            time_end=datetime(2026, 1, 1, 9, 16, tzinfo=UTC),
            interval_confidence=0.97,
            processing_version="interval-v1",
            review_notes="manually confirmed against neighboring files",
        ),
    )
    assert reviewed.metadata_state == SourceFileMetadataState.REVIEWED
    assert reviewed.reviewed_by_user_id == "user_test123"
    assert reviewed.reviewed_at is not None


def test_record_source_files_infers_time_and_updates_coverage() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id="source_test123",
            user_id="user_test123",
            source_id="screenpipe",
            display_name="Screenpipe Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    created = service.record_source_files_for_import(
        user_id="user_test123",
        owned_source_id="source_test123",
        import_run_id="import_test123",
        source_id="screenpipe",
        files=[
            SourceFileCreateInput(
                content_hash="hash123",
                bucket="guardian-ingest-bucket-3-26",
                object_path=(
                    "files/user_test123/source_test123/"
                    "MacBook Air Microphone (input)_2026-03-28_22-39-10.mp4"
                ),
                filename="MacBook Air Microphone (input)_2026-03-28_22-39-10.mp4",
                content_type="video/mp4",
                size_bytes=123,
                original_relative_path=(
                    "data/MacBook Air Microphone (input)_2026-03-28_22-39-10.mp4"
                ),
                source_modified_at=datetime(2026, 3, 28, 22, 43, tzinfo=UTC),
            )
        ],
    )

    assert created[0].metadata_state == SourceFileMetadataState.INFERRED
    assert created[0].time_start == datetime(2026, 3, 28, 22, 39, 10, tzinfo=UTC)
    assert created[0].time_basis == "screenpipe_filename"

    coverage = service.get_source_time_coverage(
        user_id="user_test123",
        owned_source_id="source_test123",
        year=2026,
    )
    hour_index = 86 * 24 + 22
    assert coverage.covered_hour_count == 1
    assert coverage.coverage[hour_index] is True


def test_new_source_returns_empty_coverage() -> None:
    owned_source_repository = InMemoryOwnedSourceRepository()
    source_file_repository = InMemorySourceFileRepository()
    source_time_coverage_repository = InMemorySourceTimeCoverageRepository()
    service = SourceFileService(
        source_file_repository,
        source_time_coverage_repository,
        owned_source_repository,
    )
    owned_source_repository.save_owned_source(
        OwnedSource(
            owned_source_id="source_empty123",
            user_id="user_test123",
            source_id="gopro",
            display_name="GoPro Source",
            created_at=datetime.now(tz=UTC),
            updated_at=datetime.now(tz=UTC),
        )
    )

    coverage = service.get_source_time_coverage(
        user_id="user_test123",
        owned_source_id="source_empty123",
        year=2026,
    )

    assert coverage.covered_hour_count == 0
    assert any(coverage.coverage) is False
