from datetime import UTC, datetime
from enum import StrEnum

from pydantic import BaseModel, Field, model_validator


class SourceFileMetadataState(StrEnum):
    PENDING = "pending"
    INFERRED = "inferred"
    REVIEW_REQUIRED = "review_required"
    REVIEWED = "reviewed"
    ERROR = "error"


class SourceFile(BaseModel):
    source_file_id: str
    import_run_id: str
    user_id: str
    owned_source_id: str
    source_id: str
    content_hash: str
    bucket: str
    object_path: str
    filename: str
    materialized_filename: str
    content_type: str | None = None
    size_bytes: int = Field(ge=0)
    original_relative_path: str
    source_modified_at: datetime
    metadata_state: SourceFileMetadataState = SourceFileMetadataState.PENDING
    time_start: datetime | None = None
    time_end: datetime | None = None
    interval_confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    time_basis: str | None = None
    time_zone_name: str | None = None
    time_timezone_source: str | None = None
    processing_version: str | None = None
    metadata_artifact_uri: str | None = None
    review_notes: str | None = None
    reviewed_by_user_id: str | None = None
    reviewed_at: datetime | None = None
    metadata_error: str | None = None
    metadata_updated_at: datetime | None = None
    created_at: datetime
    updated_at: datetime

    @model_validator(mode="after")
    def validate_metadata_fields(self) -> "SourceFile":
        if (
            self.time_start is not None
            and self.time_end is not None
            and self.time_end < self.time_start
        ):
            raise ValueError("time_end must be greater than or equal to time_start")
        if self.metadata_state in {
            SourceFileMetadataState.INFERRED,
            SourceFileMetadataState.REVIEWED,
        } and (self.time_start is None or self.time_end is None):
            raise ValueError("inferred and reviewed files must include time_start and time_end")
        if self.metadata_state == SourceFileMetadataState.REVIEWED and self.reviewed_at is None:
            raise ValueError("reviewed files must include reviewed_at")
        return self


class SourceFileHashIndexEntry(BaseModel):
    index_id: str
    owned_source_id: str
    content_hash: str
    source_file_id: str
    object_path: str
    bucket: str
    updated_at: datetime


class SourceFileCreateInput(BaseModel):
    content_hash: str
    bucket: str
    object_path: str
    filename: str
    content_type: str | None = None
    size_bytes: int = Field(ge=0)
    original_relative_path: str
    source_modified_at: datetime


class SourceFileMetadataUpdateRequest(BaseModel):
    metadata_state: SourceFileMetadataState
    time_start: datetime | None = None
    time_end: datetime | None = None
    interval_confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    time_basis: str | None = None
    time_zone_name: str | None = None
    time_timezone_source: str | None = None
    processing_version: str | None = None
    metadata_artifact_uri: str | None = None
    review_notes: str | None = None
    metadata_error: str | None = None

    @model_validator(mode="after")
    def validate_interval_window(self) -> "SourceFileMetadataUpdateRequest":
        if (
            self.time_start is not None
            and self.time_end is not None
            and self.time_end < self.time_start
        ):
            raise ValueError("time_end must be greater than or equal to time_start")
        return self


def hours_in_year(year: int) -> int:
    start = datetime(year, 1, 1, tzinfo=UTC)
    end = datetime(year + 1, 1, 1, tzinfo=UTC)
    return int((end - start).total_seconds() // 3600)


class SourceTimeCoverageRecord(BaseModel):
    coverage_id: str
    user_id: str
    owned_source_id: str
    year: int
    hour_counts: list[int]
    covered_hour_count: int = Field(ge=0)
    created_at: datetime
    updated_at: datetime

    @model_validator(mode="after")
    def validate_shape(self) -> "SourceTimeCoverageRecord":
        expected_length = hours_in_year(self.year)
        if len(self.hour_counts) != expected_length:
            raise ValueError(
                f"hour_counts must contain {expected_length} items for year {self.year}"
            )
        if any(count < 0 for count in self.hour_counts):
            raise ValueError("hour_counts may not contain negative values")
        return self


class SourceTimeCoverageResponse(BaseModel):
    owned_source_id: str
    year: int
    start_at: datetime
    end_at: datetime
    total_hour_count: int = Field(ge=0)
    covered_hour_count: int = Field(ge=0)
    coverage: list[bool]
    updated_at: datetime | None = None
