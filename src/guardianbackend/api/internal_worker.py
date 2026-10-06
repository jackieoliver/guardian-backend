from typing import Annotated

from fastapi import APIRouter, Depends

from guardianbackend.imports import (
    ImportWorkerService,
    ProcessImportRunRequest,
    ProcessImportRunResponse,
    ProcessImportShardRequest,
    ProcessImportShardResponse,
)
from guardianbackend.vm import (
    CompiledOutputSyncService,
    CompilerSourceSyncService,
    ProcessUserBootstrapRequest,
    ProcessUserBootstrapResponse,
    SyncCompiledOutputsRequest,
    SyncCompiledOutputsResponse,
    SyncSourceFilesToCompilerRequest,
    SyncSourceFilesToCompilerResponse,
    UserBootstrapService,
)

from .deps import (
    get_compiled_output_sync_service,
    get_compiler_source_sync_service,
    get_import_worker_service,
    get_user_bootstrap_service,
    require_internal_worker_token,
)

router = APIRouter()


@router.post(
    "/internal/process-import-shard",
    response_model=ProcessImportShardResponse,
    dependencies=[Depends(require_internal_worker_token)],
)
def process_import_shard(
    request: ProcessImportShardRequest,
    worker_service: Annotated[
        ImportWorkerService,
        Depends(get_import_worker_service),
    ],
) -> ProcessImportShardResponse:
    return worker_service.process_import_shard(
        import_run_id=request.import_run_id,
        import_shard_id=request.import_shard_id,
    )


@router.post(
    "/internal/process-import-run",
    response_model=ProcessImportRunResponse,
    dependencies=[Depends(require_internal_worker_token)],
)
def process_import_run(
    request: ProcessImportRunRequest,
    worker_service: Annotated[
        ImportWorkerService,
        Depends(get_import_worker_service),
    ],
) -> ProcessImportRunResponse:
    return worker_service.process_import_run(request.import_run_id)


@router.post(
    "/internal/bootstrap-user",
    response_model=ProcessUserBootstrapResponse,
    dependencies=[Depends(require_internal_worker_token)],
)
def bootstrap_user(
    request: ProcessUserBootstrapRequest,
    bootstrap_service: Annotated[
        UserBootstrapService,
        Depends(get_user_bootstrap_service),
    ],
) -> ProcessUserBootstrapResponse:
    return bootstrap_service.process_user_bootstrap(request.user_id)


@router.post(
    "/internal/sync-compiled-outputs",
    response_model=SyncCompiledOutputsResponse,
    dependencies=[Depends(require_internal_worker_token)],
)
def sync_compiled_outputs(
    request: SyncCompiledOutputsRequest,
    sync_service: Annotated[
        CompiledOutputSyncService,
        Depends(get_compiled_output_sync_service),
    ],
) -> SyncCompiledOutputsResponse:
    return sync_service.sync_user_compiled_outputs(request.user_id)


@router.post(
    "/internal/sync-source-files-to-compiler",
    response_model=SyncSourceFilesToCompilerResponse,
    dependencies=[Depends(require_internal_worker_token)],
)
def sync_source_files_to_compiler(
    request: SyncSourceFilesToCompilerRequest,
    sync_service: Annotated[
        CompilerSourceSyncService,
        Depends(get_compiler_source_sync_service),
    ],
) -> SyncSourceFilesToCompilerResponse:
    return sync_service.sync_source_files_to_compiler(
        user_id=request.user_id,
        owned_source_id=request.owned_source_id,
    )
