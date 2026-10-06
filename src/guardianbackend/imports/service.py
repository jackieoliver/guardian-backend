import hashlib

from fastapi import HTTPException, status

from guardianbackend.domain import new_import_run_id, new_import_shard_id, utc_now
from guardianbackend.files import SourceFileService
from guardianbackend.sources import OwnedSource, OwnedSourceRepository
from guardianbackend.storage import ObjectStore
from guardianbackend.storage.paths import build_transport_object_path

from .models import (
    ImportPlanMatch,
    ImportPlanRequest,
    ImportPlanResponse,
    ImportQueueItem,
    ImportRun,
    ImportRunCreateRequest,
    ImportRunStatusUpdateRequest,
    ImportShard,
    ImportShardCreateRequest,
)
from .repository import ImportRunRepository, ImportShardRepository
from .tasks import ImportProcessingDispatcher


class ImportService:
    def __init__(
        self,
        import_run_repository: ImportRunRepository,
        import_shard_repository: ImportShardRepository,
        owned_source_repository: OwnedSourceRepository,
        source_file_service: SourceFileService,
        processing_dispatcher: ImportProcessingDispatcher,
    ) -> None:
        self._import_run_repository = import_run_repository
        self._import_shard_repository = import_shard_repository
        self._owned_source_repository = owned_source_repository
        self._source_file_service = source_file_service
        self._processing_dispatcher = processing_dispatcher

    def list_import_queue_for_user(
        self,
        user_id: str,
        *,
        limit: int = 20,
        include_completed: bool = False,
    ) -> list[ImportQueueItem]:
        owned_sources = self._owned_source_repository.list_owned_sources_for_user(user_id)
        source_names = {
            owned_source.owned_source_id: owned_source.display_name
            for owned_source in owned_sources
        }
        candidate_limit = max(limit * 3, limit)
        runs = self._import_run_repository.list_import_runs_for_user(
            user_id,
            limit=candidate_limit,
        )
        sorted_runs = sorted(runs, key=lambda run: run.updated_at, reverse=True)
        if not include_completed:
            sorted_runs = [
                run
                for run in sorted_runs
                if run.status not in {"completed", "canceled"}
            ]
        queue_items = [
            ImportQueueItem(
                import_run_id=run.import_run_id,
                owned_source_id=run.owned_source_id,
                source_id=run.source_id,
                source_display_name=source_names.get(run.owned_source_id, run.source_id),
                status=run.status,
                total_candidate_file_count=run.total_candidate_file_count,
                transport_shard_count=run.transport_shard_count,
                uploaded_transport_shard_count=run.uploaded_transport_shard_count,
                processed_transport_shard_count=run.processed_transport_shard_count,
                canonical_file_count=run.canonical_file_count,
                created_at=run.created_at,
                updated_at=run.updated_at,
                completed_at=run.completed_at,
                error=run.error,
            )
            for run in sorted_runs[:limit]
        ]
        return queue_items

    def list_import_runs_for_source(
        self,
        user_id: str,
        owned_source_id: str,
        *,
        limit: int = 50,
    ) -> list[ImportRun]:
        self._require_owned_source_for_user(user_id, owned_source_id)
        return self._import_run_repository.list_import_runs_for_owned_source(
            owned_source_id,
            limit=limit,
        )

    def create_import_run(
        self,
        user_id: str,
        owned_source_id: str,
        request: ImportRunCreateRequest,
    ) -> ImportRun:
        owned_source = self._require_owned_source_for_user(user_id, owned_source_id)
        now = utc_now()
        import_run = ImportRun(
            import_run_id=new_import_run_id(),
            user_id=user_id,
            owned_source_id=owned_source_id,
            source_id=owned_source.source_id,
            client_id=request.client_id,
            source_snapshot_label=request.source_snapshot_label,
            total_candidate_file_count=request.total_candidate_file_count,
            total_candidate_size_bytes=request.total_candidate_size_bytes,
            created_at=now,
            updated_at=now,
        )
        saved_run = self._import_run_repository.save_import_run(import_run)
        updated_source = owned_source.model_copy(
            update={"current_import_run_id": saved_run.import_run_id, "updated_at": now}
        )
        self._owned_source_repository.save_owned_source(updated_source)
        return saved_run

    def get_import_run_for_source(
        self,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
    ) -> ImportRun:
        self._require_owned_source_for_user(user_id, owned_source_id)
        import_run = self._import_run_repository.get_import_run(import_run_id)
        if (
            import_run is None
            or import_run.user_id != user_id
            or import_run.owned_source_id != owned_source_id
        ):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Import run not found",
            )
        return import_run

    def plan_import_run(
        self,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
        request: ImportPlanRequest,
    ) -> ImportPlanResponse:
        self.get_import_run_for_source(user_id, owned_source_id, import_run_id)
        existing_files = self._source_file_service.find_source_files_by_hashes_for_owned_source(
            user_id,
            owned_source_id,
            {candidate.content_hash for candidate in request.candidates},
        )
        existing_by_hash = {
            source_file.content_hash: source_file for source_file in existing_files
        }
        known: list[ImportPlanMatch] = []
        missing: list[ImportPlanMatch] = []

        for candidate in request.candidates:
            existing = existing_by_hash.get(candidate.content_hash)
            match = ImportPlanMatch(
                content_hash=candidate.content_hash,
                original_relative_path=candidate.original_relative_path,
                size_bytes=candidate.size_bytes,
                source_modified_at=candidate.source_modified_at,
                known=existing is not None,
                source_file_id=existing.source_file_id if existing else None,
                object_path=existing.object_path if existing else None,
            )
            if existing is not None:
                known.append(match)
            else:
                missing.append(match)

        return ImportPlanResponse(
            known=known,
            missing=missing,
            known_count=len(known),
            missing_count=len(missing),
        )

    def create_import_shards(
        self,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
        request: ImportShardCreateRequest,
        *,
        transport_prefix: str = "tmp-imports",
    ) -> list[ImportShard]:
        import_run = self.get_import_run_for_source(user_id, owned_source_id, import_run_id)
        now = utc_now()
        created_shards: list[ImportShard] = []
        for shard_request in request.shards:
            object_path = shard_request.object_path or build_transport_object_path(
                transport_prefix=transport_prefix,
                user_id=user_id,
                owned_source_id=owned_source_id,
                import_run_id=import_run.import_run_id,
                filename=shard_request.filename,
            )
            shard = ImportShard(
                import_shard_id=new_import_shard_id(),
                import_run_id=import_run.import_run_id,
                user_id=user_id,
                owned_source_id=owned_source_id,
                shard_index=shard_request.shard_index,
                filename=shard_request.filename,
                object_path=object_path,
                content_hash=shard_request.content_hash,
                file_count=shard_request.file_count,
                total_size_bytes=shard_request.total_size_bytes,
                created_at=now,
            )
            created_shards.append(self._import_shard_repository.save_import_shard(shard))

        shard_count = len(self._import_shard_repository.list_import_shards_for_run(import_run_id))
        updated_run = import_run.model_copy(
            update={
                "status": "uploading",
                "transport_shard_count": shard_count,
                "updated_at": now,
            }
        )
        self._import_run_repository.save_import_run(updated_run)
        return created_shards

    def get_import_shard_for_source(
        self,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
        import_shard_id: str,
    ) -> ImportShard:
        self.get_import_run_for_source(user_id, owned_source_id, import_run_id)
        shard = self._import_shard_repository.get_import_shard(import_shard_id)
        if (
            shard is None
            or shard.user_id != user_id
            or shard.owned_source_id != owned_source_id
            or shard.import_run_id != import_run_id
        ):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Import shard not found",
            )
        return shard

    def upload_import_shard_content(
        self,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
        import_shard_id: str,
        *,
        data: bytes,
        bucket: str,
        object_store: ObjectStore,
        content_type: str | None = None,
    ) -> ImportShard:
        if not data:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Import shard payload is empty",
            )

        import_run = self.get_import_run_for_source(user_id, owned_source_id, import_run_id)
        shard = self.get_import_shard_for_source(
            user_id,
            owned_source_id,
            import_run_id,
            import_shard_id,
        )
        if shard.status in {"processing", "processed"}:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Import shard can no longer accept uploaded content",
            )

        digest = hashlib.sha256(data).hexdigest()
        if digest != shard.content_hash:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Import shard content hash did not match the declared transport hash",
            )

        object_store.upload_bytes(
            bucket=bucket,
            object_path=shard.object_path,
            data=data,
            content_type=content_type,
        )

        now = utc_now()
        saved_shard = self._import_shard_repository.save_import_shard(
            shard.model_copy(
                update={
                    "status": "uploaded",
                    "uploaded_at": shard.uploaded_at or now,
                    "error": None,
                }
            )
        )

        latest_shards = self._import_shard_repository.list_import_shards_for_run(import_run_id)
        uploaded_count = sum(
            1
            for latest_shard in latest_shards
            if latest_shard.status in {"uploaded", "processing", "processed"}
        )
        self._import_run_repository.save_import_run(
            import_run.model_copy(
                update={
                    "status": "uploading",
                    "uploaded_transport_shard_count": uploaded_count,
                    "updated_at": now,
                    "error": None,
                }
            )
        )
        return saved_shard

    def complete_import_run(
        self,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
    ) -> ImportRun:
        import_run = self.get_import_run_for_source(user_id, owned_source_id, import_run_id)
        now = utc_now()
        shards = self._import_shard_repository.list_import_shards_for_run(import_run_id)
        for shard in shards:
            if shard.status == "created":
                self._import_shard_repository.save_import_shard(
                    shard.model_copy(update={"status": "uploaded", "uploaded_at": now})
                )

        updated_run = import_run.model_copy(
            update={
                "status": "processing",
                "uploaded_transport_shard_count": len(shards),
                "updated_at": now,
            }
        )
        saved_run = self._import_run_repository.save_import_run(updated_run)
        for shard in self._import_shard_repository.list_import_shards_for_run(import_run_id):
            if shard.status != "uploaded":
                continue
            self._processing_dispatcher.dispatch_import_shard(
                import_run_id=import_run_id,
                import_shard_id=shard.import_shard_id,
            )
        return saved_run

    def cancel_import_run(
        self,
        user_id: str,
        owned_source_id: str,
        import_run_id: str,
        request: ImportRunStatusUpdateRequest,
    ) -> ImportRun:
        import_run = self.get_import_run_for_source(user_id, owned_source_id, import_run_id)
        now = utc_now()
        updated_run = import_run.model_copy(
            update={
                "status": "canceled",
                "error": request.error,
                "completed_at": now,
                "updated_at": now,
            }
        )
        saved_run = self._import_run_repository.save_import_run(updated_run)
        owned_source = self._require_owned_source_for_user(user_id, owned_source_id)
        if owned_source.current_import_run_id == import_run_id:
            self._owned_source_repository.save_owned_source(
                owned_source.model_copy(update={"current_import_run_id": None, "updated_at": now})
            )
        return saved_run

    def _require_owned_source_for_user(self, user_id: str, owned_source_id: str) -> OwnedSource:
        owned_source = self._owned_source_repository.get_owned_source(owned_source_id)
        if owned_source is None or owned_source.user_id != user_id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Owned source not found",
            )
        return owned_source
