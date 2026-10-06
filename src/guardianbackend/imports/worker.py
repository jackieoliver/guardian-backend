import io
import json
import tarfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from typing import TYPE_CHECKING

from google.api_core.exceptions import NotFound
from pydantic import BaseModel, Field

from guardianbackend.config import Settings
from guardianbackend.domain import utc_now
from guardianbackend.files import (
    SourceFileCreateInput,
    SourceFileService,
    build_materialized_filename,
)
from guardianbackend.sources import OwnedSourceRepository
from guardianbackend.storage import ObjectStore, build_canonical_file_object_path

from .models import (
    ImportRun,
    ImportShard,
    ProcessImportShardResponse,
)
from .repository import ImportRunRepository, ImportShardRepository

if TYPE_CHECKING:
    from guardianbackend.vm import ApprovedSourceMirrorService, CompilerSourceSyncService


class TransportManifestFile(BaseModel):
    archive_path: str
    original_relative_path: str
    filename: str
    content_hash: str
    size_bytes: int = Field(ge=0)
    content_type: str | None = None
    source_modified_at: datetime


class TransportManifest(BaseModel):
    files: list[TransportManifestFile]


class ProcessImportRunRequest(BaseModel):
    import_run_id: str


class ProcessImportRunResponse(BaseModel):
    import_run_id: str
    status: str
    processed_shard_count: int
    canonical_file_count: int


class ImportWorkerService:
    def __init__(
        self,
        settings: Settings,
        import_run_repository: ImportRunRepository,
        import_shard_repository: ImportShardRepository,
        owned_source_repository: OwnedSourceRepository,
        source_file_service: SourceFileService,
        object_store: ObjectStore,
        compiler_source_sync_service: "CompilerSourceSyncService | None" = None,
        approved_source_mirror_service: "ApprovedSourceMirrorService | None" = None,
    ) -> None:
        self._settings = settings
        self._import_run_repository = import_run_repository
        self._import_shard_repository = import_shard_repository
        self._owned_source_repository = owned_source_repository
        self._source_file_service = source_file_service
        self._object_store = object_store
        self._compiler_source_sync_service = compiler_source_sync_service
        self._approved_source_mirror_service = approved_source_mirror_service

    def process_import_run(self, import_run_id: str) -> ProcessImportRunResponse:
        import_run = self._require_import_run(import_run_id)
        if self._settings.gcs_bucket_name is None:
            raise RuntimeError("gcs_bucket_name is required for import processing")
        if import_run.status == "completed":
            return ProcessImportRunResponse(
                import_run_id=import_run_id,
                status="completed",
                processed_shard_count=import_run.processed_transport_shard_count,
                canonical_file_count=import_run.canonical_file_count,
            )

        processable_shards = sorted(
            self._import_shard_repository.list_import_shards_for_run(import_run_id),
            key=lambda shard: shard.shard_index,
        )
        if not processable_shards:
            return ProcessImportRunResponse(
                import_run_id=import_run_id,
                status=import_run.status,
                processed_shard_count=0,
                canonical_file_count=import_run.canonical_file_count,
            )

        processed_shard_count = 0
        created_source_files = 0
        now = utc_now()
        try:
            for shard in processable_shards:
                claimed_shard = self._import_shard_repository.claim_uploaded_shard(
                    shard.import_shard_id
                )
                if claimed_shard is None:
                    continue
                created_count = self._process_uploaded_shard(import_run, claimed_shard)
                created_source_files += created_count
                processed_shard_count += 1
                import_run = self._refresh_run_aggregate(import_run.import_run_id)

            latest_run = self._require_import_run(import_run_id)
            updated_run = self._finalize_run_if_complete(latest_run, now=now)
            return ProcessImportRunResponse(
                import_run_id=import_run_id,
                status=updated_run.status,
                processed_shard_count=processed_shard_count,
                canonical_file_count=updated_run.canonical_file_count,
            )
        except Exception as exc:
            failed_run = import_run.model_copy(
                update={"status": "failed", "updated_at": now, "error": str(exc)}
            )
            self._import_run_repository.save_import_run(failed_run)
            raise

    def process_import_shard(
        self,
        *,
        import_run_id: str,
        import_shard_id: str,
    ) -> ProcessImportShardResponse:
        import_run = self._require_import_run(import_run_id)
        if import_run.status == "completed":
            return ProcessImportShardResponse(
                import_run_id=import_run_id,
                import_shard_id=import_shard_id,
                shard_status="processed",
                import_run_status="completed",
                canonical_file_count=import_run.canonical_file_count,
            )

        claimed_shard = self._import_shard_repository.claim_uploaded_shard(import_shard_id)
        if claimed_shard is None:
            latest_run = self._require_import_run(import_run_id)
            latest_shards = self._import_shard_repository.list_import_shards_for_run(import_run_id)
            matching_shard = next(
                (shard for shard in latest_shards if shard.import_shard_id == import_shard_id),
                None,
            )
            return ProcessImportShardResponse(
                import_run_id=import_run_id,
                import_shard_id=import_shard_id,
                shard_status=matching_shard.status if matching_shard is not None else "missing",
                import_run_status=latest_run.status,
                canonical_file_count=latest_run.canonical_file_count,
            )

        now = utc_now()
        shard_processed = False
        try:
            self._process_uploaded_shard(import_run, claimed_shard)
            shard_processed = True
            updated_run = self._refresh_run_aggregate(import_run_id)
            finalized_run = self._finalize_run_if_complete(updated_run, now=now)
            return ProcessImportShardResponse(
                import_run_id=import_run_id,
                import_shard_id=import_shard_id,
                shard_status="processed",
                import_run_status=finalized_run.status,
                canonical_file_count=finalized_run.canonical_file_count,
            )
        except Exception as exc:
            if not shard_processed:
                self._import_shard_repository.save_import_shard(
                    claimed_shard.model_copy(update={"status": "uploaded", "error": str(exc)})
                )
            failed_run = self._require_import_run(import_run_id).model_copy(
                update={"status": "failed", "updated_at": now, "error": str(exc)}
            )
            self._import_run_repository.save_import_run(failed_run)
            raise

    def _process_uploaded_shard(self, import_run: ImportRun, shard: ImportShard) -> int:
        if self._settings.gcs_bucket_name is None:
            raise RuntimeError("gcs_bucket_name is required for import processing")

        archive_bytes = self._object_store.download_bytes(
            bucket=self._settings.gcs_bucket_name,
            object_path=shard.object_path,
        )
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:*") as archive:
            manifest_member = archive.extractfile("manifest.json")
            if manifest_member is None:
                raise RuntimeError("transport shard missing manifest.json")
            manifest = TransportManifest.model_validate(json.loads(manifest_member.read()))
            upload_jobs: list[tuple[SourceFileCreateInput, bytes]] = []
            for manifest_file in manifest.files:
                file_member = archive.extractfile(manifest_file.archive_path)
                if file_member is None:
                    raise RuntimeError(
                        f"transport shard missing archive member {manifest_file.archive_path}"
                    )
                file_bytes = file_member.read()
                materialized_filename = build_materialized_filename(
                    manifest_file.original_relative_path,
                    manifest_file.content_hash,
                )
                canonical_object_path = build_canonical_file_object_path(
                    files_prefix=self._settings.gcs_files_prefix,
                    user_id=import_run.user_id,
                    owned_source_id=import_run.owned_source_id,
                    materialized_filename=materialized_filename,
                )
                upload_jobs.append(
                    (
                        SourceFileCreateInput(
                            content_hash=manifest_file.content_hash,
                            bucket=self._settings.gcs_bucket_name,
                            object_path=canonical_object_path,
                            filename=manifest_file.filename,
                            content_type=manifest_file.content_type,
                            size_bytes=manifest_file.size_bytes,
                            original_relative_path=manifest_file.original_relative_path,
                            source_modified_at=manifest_file.source_modified_at,
                        ),
                        file_bytes,
                    )
                )

        max_workers = max(1, min(self._settings.import_worker_file_concurrency, len(upload_jobs)))
        if upload_jobs:
            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                futures = [
                    executor.submit(
                        self._object_store.upload_bytes,
                        bucket=self._settings.gcs_bucket_name,
                        object_path=source_file.object_path,
                        data=file_bytes,
                        content_type=source_file.content_type,
                    )
                    for source_file, file_bytes in upload_jobs
                ]
                for future in futures:
                    future.result()
        source_files = [source_file for source_file, _ in upload_jobs]

        self._source_file_service.record_source_files_for_import(
            user_id=import_run.user_id,
            owned_source_id=import_run.owned_source_id,
            import_run_id=import_run.import_run_id,
            source_id=import_run.source_id,
            files=source_files,
        )
        try:
            self._object_store.delete_object(
                bucket=self._settings.gcs_bucket_name,
                object_path=shard.object_path,
            )
        except NotFound:
            # Duplicate task execution or manual reruns may find the transport blob already gone.
            pass
        self._import_shard_repository.save_import_shard(
            shard.model_copy(
                update={"status": "processed", "processed_at": utc_now(), "error": None}
            )
        )
        return len(source_files)

    def _refresh_run_aggregate(self, import_run_id: str) -> ImportRun:
        latest_run = self._require_import_run(import_run_id)
        latest_shards = self._import_shard_repository.list_import_shards_for_run(import_run_id)
        processed_shards = [shard for shard in latest_shards if shard.status == "processed"]
        failed_shards = [shard for shard in latest_shards if shard.status == "failed"]
        updated_run = latest_run.model_copy(
            update={
                "processed_transport_shard_count": len(processed_shards),
                "failed_transport_shard_count": len(failed_shards),
                "canonical_file_count": sum(shard.file_count for shard in processed_shards),
                "updated_at": utc_now(),
                "error": latest_run.error if failed_shards else None,
            }
        )
        return self._import_run_repository.save_import_run(updated_run)

    def _finalize_run_if_complete(self, import_run: ImportRun, *, now: datetime) -> ImportRun:
        latest_shards = self._import_shard_repository.list_import_shards_for_run(
            import_run.import_run_id
        )
        if not latest_shards or not all(shard.status == "processed" for shard in latest_shards):
            return import_run
        processed_shard_count = len(latest_shards)
        canonical_file_count = sum(shard.file_count for shard in latest_shards)
        updated_run = import_run.model_copy(
            update={
                "status": "completed",
                "processed_transport_shard_count": processed_shard_count,
                "canonical_file_count": canonical_file_count,
                "completed_at": now,
                "updated_at": now,
                "error": None,
            }
        )
        saved_run = self._import_run_repository.save_import_run(updated_run)
        owned_source = self._owned_source_repository.get_owned_source(import_run.owned_source_id)
        if (
            owned_source is not None
            and owned_source.current_import_run_id == import_run.import_run_id
        ):
            self._owned_source_repository.save_owned_source(
                owned_source.model_copy(
                    update={
                        "current_import_run_id": None,
                        "last_import_completed_at": now,
                        "updated_at": now,
                    }
                )
            )
        if self._compiler_source_sync_service is not None:
            self._compiler_source_sync_service.sync_source_files_to_compiler(
                user_id=import_run.user_id,
                owned_source_id=import_run.owned_source_id,
            )
        if self._approved_source_mirror_service is not None:
            self._approved_source_mirror_service.mirror_source_to_runtime(
                user_id=import_run.user_id,
                owned_source_id=import_run.owned_source_id,
            )
        return saved_run

    def _require_import_run(self, import_run_id: str) -> ImportRun:
        import_run = self._import_run_repository.get_import_run(import_run_id)
        if import_run is None:
            raise RuntimeError("import run not found")
        return import_run
