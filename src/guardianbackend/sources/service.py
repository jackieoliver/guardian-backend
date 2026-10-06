from fastapi import HTTPException, status

from guardianbackend.domain import new_owned_source_id, utc_now

from .catalog import default_source_types
from .models import OwnedSource, OwnedSourceCreateRequest, SourceType
from .repository import OwnedSourceRepository, SourceTypeRepository


class OwnedSourceService:
    def __init__(
        self,
        owned_source_repository: OwnedSourceRepository,
        source_type_repository: SourceTypeRepository,
    ) -> None:
        self._owned_source_repository = owned_source_repository
        self._source_type_repository = source_type_repository
        self._source_types_cache: list[SourceType] | None = None

    def list_source_types(self) -> list[SourceType]:
        if self._source_types_cache is not None:
            return self._source_types_cache
        source_types = self._source_type_repository.list_source_types() or default_source_types()
        self._source_types_cache = source_types
        return source_types

    def list_owned_sources_for_user(self, user_id: str) -> list[OwnedSource]:
        return self._owned_source_repository.list_owned_sources_for_user(user_id)

    def add_owned_source_for_user(
        self, user_id: str, request: OwnedSourceCreateRequest
    ) -> OwnedSource:
        valid_source_ids = {source_type.source_id for source_type in self.list_source_types()}
        if request.source_id not in valid_source_ids:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Unknown source type: {request.source_id}",
            )
        now = utc_now()
        owned_source = OwnedSource(
            owned_source_id=new_owned_source_id(),
            user_id=user_id,
            source_id=request.source_id,
            display_name=request.display_name,
            created_at=now,
            updated_at=now,
        )
        return self._owned_source_repository.save_owned_source(owned_source)

    def remove_owned_source_for_user(self, user_id: str, owned_source_id: str) -> None:
        owned_source = self._owned_source_repository.get_owned_source(owned_source_id)
        if owned_source is None or owned_source.user_id != user_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Owned source not found",
            )
        if owned_source.current_import_run_id is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Owned source has an active import run",
            )
        self._owned_source_repository.delete_owned_source(owned_source_id)
