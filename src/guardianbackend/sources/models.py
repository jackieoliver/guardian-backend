from datetime import datetime

from pydantic import BaseModel


class SourceType(BaseModel):
    source_id: str
    source_name: str


class OwnedSource(BaseModel):
    owned_source_id: str
    user_id: str
    source_id: str
    display_name: str
    created_at: datetime
    updated_at: datetime
    last_import_completed_at: datetime | None = None
    current_import_run_id: str | None = None


class OwnedSourceCreateRequest(BaseModel):
    source_id: str
    display_name: str
