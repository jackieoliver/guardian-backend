from datetime import UTC, datetime
from pathlib import Path

from fastapi import HTTPException, status

from guardianbackend.domain import new_source_file_id, utc_now
from guardianbackend.sources import OwnedSourceRepository

from .models import (
    SourceFile,
    SourceFileCreateInput,
    SourceFileMetadataState,
    SourceFileMetadataUpdateRequest,
    SourceTimeCoverageRecord,
    SourceTimeCoverageResponse,
    hours_in_year,
)
from .repository import (
    SourceFileRepository,
    SourceTimeCoverageRepository,
    build_source_time_coverage_id,
)
from .time_inference import infer_rough_time_interval


def build_materialized_filename(original_relative_path: str, content_hash: str) -> str:
    suffix = content_hash[:12]
    original_name = Path(original_relative_path).name or "file"
    stem = Path(original_name).stem or "file"
    extension = Path(original_name).suffix
    return f"{stem}-{suffix}{extension}"


class SourceFileService:
    _ALLOWED_METADATA_TRANSITIONS: dict[SourceFileMetadataState, set[SourceFileMetadataState]] = {
        SourceFileMetadataState.PENDING: {
            SourceFileMetadataState.INFERRED,
            SourceFileMetadataState.REVIEW_REQUIRED,
            SourceFileMetadataState.ERROR,
        },
        SourceFileMetadataState.INFERRED: {
            SourceFileMetadataState.INFERRED,
            SourceFileMetadataState.REVIEW_REQUIRED,
            SourceFileMetadataState.REVIEWED,
            SourceFileMetadataState.ERROR,
        },
        SourceFileMetadataState.REVIEW_REQUIRED: {
            SourceFileMetadataState.REVIEW_REQUIRED,
            SourceFileMetadataState.INFERRED,
            SourceFileMetadataState.REVIEWED,
            SourceFileMetadataState.ERROR,
        },
        SourceFileMetadataState.REVIEWED: {
            SourceFileMetadataState.REVIEWED,
            SourceFileMetadataState.REVIEW_REQUIRED,
            SourceFileMetadataState.ERROR,
        },
        SourceFileMetadataState.ERROR: {
            SourceFileMetadataState.ERROR,
            SourceFileMetadataState.PENDING,
            SourceFileMetadataState.REVIEW_REQUIRED,
            SourceFileMetadataState.INFERRED,
        },
    }

    def __init__(
        self,
        source_file_repository: SourceFileRepository,
        source_time_coverage_repository: SourceTimeCoverageRepository,
        owned_source_repository: OwnedSourceRepository,
    ) -> None:
        self._source_file_repository = source_file_repository
        self._source_time_coverage_repository = source_time_coverage_repository
        self._owned_source_repository = owned_source_repository

    def list_source_files_for_owned_source(
        self,
        user_id: str,
        owned_source_id: str,
        *,
        limit: int = 100,
    ) -> list[SourceFile]:
        owned_source = self._owned_source_repository.get_owned_source(owned_source_id)
        if owned_source is None or owned_source.user_id != user_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Owned source not found",
            )
        return self._source_file_repository.list_source_files_for_owned_source(
            owned_source_id,
            limit=limit,
        )

    def find_source_files_by_hashes_for_owned_source(
        self,
        user_id: str,
        owned_source_id: str,
        content_hashes: set[str],
    ) -> list[SourceFile]:
        owned_source = self._owned_source_repository.get_owned_source(owned_source_id)
        if owned_source is None or owned_source.user_id != user_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Owned source not found",
            )
        return self._source_file_repository.find_source_files_by_hashes(
            owned_source_id,
            content_hashes,
        )

    def record_source_files_for_import(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
        source_id: str,
        files: list[SourceFileCreateInput],
    ) -> list[SourceFile]:
        now = utc_now()
        created: list[SourceFile] = []
        for file_input in files:
            inferred = infer_rough_time_interval(
                source_id=source_id,
                filename=file_input.filename,
                original_relative_path=file_input.original_relative_path,
                source_modified_at=file_input.source_modified_at,
            )
            source_file = SourceFile(
                source_file_id=new_source_file_id(),
                import_run_id=import_run_id,
                user_id=user_id,
                owned_source_id=owned_source_id,
                source_id=source_id,
                content_hash=file_input.content_hash,
                bucket=file_input.bucket,
                object_path=file_input.object_path,
                filename=file_input.filename,
                materialized_filename=build_materialized_filename(
                    file_input.original_relative_path,
                    file_input.content_hash,
                ),
                content_type=file_input.content_type,
                size_bytes=file_input.size_bytes,
                original_relative_path=file_input.original_relative_path,
                source_modified_at=file_input.source_modified_at,
                metadata_state=SourceFileMetadataState.INFERRED,
                time_start=inferred.time_start,
                time_end=inferred.time_end,
                interval_confidence=inferred.interval_confidence,
                time_basis=inferred.time_basis,
                time_zone_name=inferred.time_zone_name,
                time_timezone_source=inferred.time_timezone_source,
                metadata_updated_at=now,
                created_at=now,
                updated_at=now,
            )
            created.append(source_file)
        saved = self._source_file_repository.save_source_files(created)
        self._apply_source_time_coverage_batch(
            user_id=user_id,
            owned_source_id=owned_source_id,
            source_files=saved,
        )
        return saved

    def update_source_file_metadata(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        source_file_id: str,
        request: SourceFileMetadataUpdateRequest,
    ) -> SourceFile:
        owned_source = self._owned_source_repository.get_owned_source(owned_source_id)
        if owned_source is None or owned_source.user_id != user_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Owned source not found",
            )

        source_file = self._source_file_repository.get_source_file(source_file_id)
        if source_file is None or source_file.owned_source_id != owned_source_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Source file not found",
            )

        allowed_next_states = self._ALLOWED_METADATA_TRANSITIONS[source_file.metadata_state]
        if request.metadata_state not in allowed_next_states:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=(
                    "Invalid source file metadata transition: "
                    f"{source_file.metadata_state} -> {request.metadata_state}"
                ),
            )

        now = utc_now()
        is_reviewed = request.metadata_state == SourceFileMetadataState.REVIEWED
        updated_source_file = source_file.model_copy(
            update={
                "metadata_state": request.metadata_state,
                "time_start": (
                    request.time_start
                    if request.time_start is not None
                    else source_file.time_start
                ),
                "time_end": (
                    request.time_end if request.time_end is not None else source_file.time_end
                ),
                "interval_confidence": (
                    request.interval_confidence
                    if request.interval_confidence is not None
                    else source_file.interval_confidence
                ),
                "time_basis": (
                    request.time_basis
                    if request.time_basis is not None
                    else source_file.time_basis
                ),
                "time_zone_name": (
                    request.time_zone_name
                    if request.time_zone_name is not None
                    else source_file.time_zone_name
                ),
                "time_timezone_source": (
                    request.time_timezone_source
                    if request.time_timezone_source is not None
                    else source_file.time_timezone_source
                ),
                "processing_version": (
                    request.processing_version
                    if request.processing_version is not None
                    else source_file.processing_version
                ),
                "metadata_artifact_uri": (
                    request.metadata_artifact_uri
                    if request.metadata_artifact_uri is not None
                    else source_file.metadata_artifact_uri
                ),
                "review_notes": (
                    request.review_notes
                    if request.review_notes is not None
                    else source_file.review_notes
                ),
                "reviewed_by_user_id": user_id if is_reviewed else None,
                "reviewed_at": now if is_reviewed else None,
                "metadata_error": request.metadata_error,
                "metadata_updated_at": now,
                "updated_at": now,
            }
        )
        saved = self._source_file_repository.save_source_file(updated_source_file)
        self._apply_source_time_coverage_delta(
            user_id=user_id,
            owned_source_id=owned_source_id,
            before=source_file,
            after=saved,
        )
        return saved

    def get_source_time_coverage(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        year: int | None = None,
    ) -> SourceTimeCoverageResponse:
        owned_source = self._owned_source_repository.get_owned_source(owned_source_id)
        if owned_source is None or owned_source.user_id != user_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Owned source not found",
            )
        coverage_year = year or utc_now().year
        record = self._source_time_coverage_repository.get_source_time_coverage(
            owned_source_id,
            coverage_year,
        )
        return self._build_coverage_response(owned_source_id, coverage_year, record)

    def _apply_source_time_coverage_batch(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        source_files: list[SourceFile],
    ) -> None:
        year = utc_now().year
        hour_deltas: dict[int, int] = {}
        for source_file in source_files:
            if source_file.time_start is None or source_file.time_end is None:
                continue
            self._add_interval_to_hour_deltas(
                hour_deltas,
                year=year,
                time_start=source_file.time_start,
                time_end=source_file.time_end,
                delta=1,
            )
        if not hour_deltas:
            return
        self._source_time_coverage_repository.apply_hour_deltas(
            user_id=user_id,
            owned_source_id=owned_source_id,
            year=year,
            hour_deltas=hour_deltas,
        )

    def _apply_source_time_coverage_delta(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        before: SourceFile,
        after: SourceFile,
    ) -> None:
        year = utc_now().year
        hour_deltas: dict[int, int] = {}
        if before.time_start is not None and before.time_end is not None:
            before_time_start = before.time_start
            before_time_end = before.time_end
            assert before_time_start is not None
            assert before_time_end is not None
            self._add_interval_to_hour_deltas(
                hour_deltas,
                year=year,
                time_start=before_time_start,
                time_end=before_time_end,
                delta=-1,
            )
        if after.time_start is not None and after.time_end is not None:
            after_time_start = after.time_start
            after_time_end = after.time_end
            assert after_time_start is not None
            assert after_time_end is not None
            self._add_interval_to_hour_deltas(
                hour_deltas,
                year=year,
                time_start=after_time_start,
                time_end=after_time_end,
                delta=1,
            )
        if not hour_deltas:
            return
        self._source_time_coverage_repository.apply_hour_deltas(
            user_id=user_id,
            owned_source_id=owned_source_id,
            year=year,
            hour_deltas=hour_deltas,
        )

    def _get_or_create_coverage_record(
        self,
        *,
        user_id: str,
        owned_source_id: str,
        year: int,
    ) -> SourceTimeCoverageRecord:
        existing = self._source_time_coverage_repository.get_source_time_coverage(
            owned_source_id,
            year,
        )
        if existing is not None:
            return existing
        now = utc_now()
        return SourceTimeCoverageRecord(
            coverage_id=build_source_time_coverage_id(owned_source_id, year),
            user_id=user_id,
            owned_source_id=owned_source_id,
            year=year,
            hour_counts=[0] * hours_in_year(year),
            covered_hour_count=0,
            created_at=now,
            updated_at=now,
        )

    def _build_coverage_response(
        self,
        owned_source_id: str,
        year: int,
        record: SourceTimeCoverageRecord | None,
    ) -> SourceTimeCoverageResponse:
        total_hour_count = hours_in_year(year)
        hour_counts = record.hour_counts if record is not None else [0] * total_hour_count
        return SourceTimeCoverageResponse(
            owned_source_id=owned_source_id,
            year=year,
            start_at=datetime(year, 1, 1, tzinfo=UTC),
            end_at=datetime(year + 1, 1, 1, tzinfo=UTC),
            total_hour_count=total_hour_count,
            covered_hour_count=(record.covered_hour_count if record is not None else 0),
            coverage=[count > 0 for count in hour_counts],
            updated_at=record.updated_at if record is not None else None,
        )

    def _add_interval_to_hour_deltas(
        self,
        hour_deltas: dict[int, int],
        *,
        year: int,
        time_start: datetime,
        time_end: datetime,
        delta: int,
    ) -> None:
        year_start = datetime(year, 1, 1, tzinfo=UTC)
        year_end = datetime(year + 1, 1, 1, tzinfo=UTC)
        start_utc = time_start.astimezone(UTC)
        end_utc = time_end.astimezone(UTC)
        if end_utc < year_start or start_utc >= year_end:
            return
        clipped_start = max(start_utc, year_start)
        clipped_end = min(end_utc, year_end)
        start_index = int((clipped_start - year_start).total_seconds() // 3600)
        end_index = int((clipped_end - year_start).total_seconds() // 3600)
        max_index = hours_in_year(year) - 1
        for index in range(max(0, start_index), min(max_index, end_index) + 1):
            hour_deltas[index] = hour_deltas.get(index, 0) + delta
