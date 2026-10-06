from datetime import datetime

from pydantic import BaseModel, Field


class ImportRun(BaseModel):
    import_run_id: str
    user_id: str
    owned_source_id: str
    source_id: str
    status: str = "created"
    client_id: str | None = None
    source_snapshot_label: str | None = None
    total_candidate_file_count: int = 0
    total_candidate_size_bytes: int = 0
    transport_shard_count: int = 0
    uploaded_transport_shard_count: int = 0
    processed_transport_shard_count: int = 0
    failed_transport_shard_count: int = 0
    canonical_file_count: int = 0
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None = None
    error: str | None = None


class ImportQueueItem(BaseModel):
    import_run_id: str
    owned_source_id: str
    source_id: str
    source_display_name: str
    status: str
    total_candidate_file_count: int = 0
    transport_shard_count: int = 0
    uploaded_transport_shard_count: int = 0
    processed_transport_shard_count: int = 0
    canonical_file_count: int = 0
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None = None
    error: str | None = None


class ImportRunCreateRequest(BaseModel):
    client_id: str | None = None
    source_snapshot_label: str | None = None
    total_candidate_file_count: int = Field(default=0, ge=0)
    total_candidate_size_bytes: int = Field(default=0, ge=0)


class ImportRunStatusUpdateRequest(BaseModel):
    error: str | None = None


class ImportPlanCandidate(BaseModel):
    content_hash: str
    original_relative_path: str
    size_bytes: int = Field(ge=0)
    source_modified_at: datetime


class ImportPlanRequest(BaseModel):
    candidates: list[ImportPlanCandidate]


class ImportPlanMatch(BaseModel):
    content_hash: str
    original_relative_path: str
    size_bytes: int
    source_modified_at: datetime
    known: bool
    source_file_id: str | None = None
    object_path: str | None = None


class ImportPlanResponse(BaseModel):
    known: list[ImportPlanMatch]
    missing: list[ImportPlanMatch]
    known_count: int
    missing_count: int


class ImportShard(BaseModel):
    import_shard_id: str
    import_run_id: str
    user_id: str
    owned_source_id: str
    status: str = "created"
    shard_index: int
    filename: str
    object_path: str
    content_hash: str
    file_count: int = Field(ge=0)
    total_size_bytes: int = Field(ge=0)
    created_at: datetime
    uploaded_at: datetime | None = None
    processed_at: datetime | None = None
    error: str | None = None


class ImportShardCreateInput(BaseModel):
    shard_index: int = Field(ge=0)
    filename: str
    object_path: str | None = None
    content_hash: str
    file_count: int = Field(ge=0)
    total_size_bytes: int = Field(ge=0)


class ImportShardCreateRequest(BaseModel):
    shards: list[ImportShardCreateInput]


class ProcessImportShardRequest(BaseModel):
    import_run_id: str
    import_shard_id: str


class ProcessImportShardResponse(BaseModel):
    import_run_id: str
    import_shard_id: str
    shard_status: str
    import_run_status: str
    canonical_file_count: int
